package portmap

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeIGD is an HTTP server that answers a UPnP device description and the SOAP
// actions this package sends. The device tree is nested, and the control URL is
// relative, so describeIGD's recursive search and URL resolution are exercised.
type fakeIGD struct {
	srv      *httptest.Server
	location string

	mu            sync.Mutex
	adds          int
	deletes       int
	lastLease     string
	lastClient    string
	lastExtPort   string
	permanentOnly bool // first non-zero-lease AddPortMapping fails with 725
	externalIP    string
	taken         map[string]bool // outside ports another machine holds: 718
}

const igdDescription = `<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
    <deviceList>
      <device>
        <deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType>
        <deviceList>
          <device>
            <deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
                <controlURL>/ctl/IPConn</controlURL>
              </service>
            </serviceList>
          </device>
        </deviceList>
      </device>
    </deviceList>
  </device>
</root>`

func newFakeIGD(t *testing.T) *fakeIGD {
	t.Helper()
	f := &fakeIGD{externalIP: "198.51.100.9"}
	mux := http.NewServeMux()
	mux.HandleFunc("/rootDesc.xml", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/xml")
		io.WriteString(w, igdDescription)
	})
	mux.HandleFunc("/ctl/IPConn", f.soap)
	f.srv = httptest.NewServer(mux)
	f.location = f.srv.URL + "/rootDesc.xml"
	t.Cleanup(f.srv.Close)
	return f
}

var tagRe = map[string]*regexp.Regexp{}

func tagValue(body []byte, tag string) string {
	re, ok := tagRe[tag]
	if !ok {
		re = regexp.MustCompile("<" + tag + ">([^<]*)</" + tag + ">")
		tagRe[tag] = re
	}
	m := re.FindSubmatch(body)
	if m == nil {
		return ""
	}
	return string(m[1])
}

func (f *fakeIGD) soap(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	action := r.Header.Get("SOAPAction")

	switch {
	case strings.Contains(action, "AddPortMapping"):
		lease := tagValue(body, "NewLeaseDuration")
		f.mu.Lock()
		f.adds++
		f.lastLease = lease
		f.lastClient = tagValue(body, "NewInternalClient")
		f.lastExtPort = tagValue(body, "NewExternalPort")
		permanentOnly := f.permanentOnly
		taken := f.taken[f.lastExtPort]
		f.mu.Unlock()
		if taken {
			writeFault(w, 718, "ConflictInMappingEntry")
			return
		}
		if permanentOnly && lease != "0" {
			writeFault(w, 725, "OnlyPermanentLeasesSupported")
			return
		}
		writeOK(w, "AddPortMapping", "")
	case strings.Contains(action, "DeletePortMapping"):
		f.mu.Lock()
		f.deletes++
		f.mu.Unlock()
		writeOK(w, "DeletePortMapping", "")
	case strings.Contains(action, "GetExternalIPAddress"):
		writeOK(w, "GetExternalIPAddress", "<NewExternalIPAddress>"+f.externalIP+"</NewExternalIPAddress>")
	default:
		writeFault(w, 401, "Invalid Action")
	}
}

func writeOK(w http.ResponseWriter, action, inner string) {
	w.Header().Set("Content-Type", "text/xml")
	io.WriteString(w, `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">`+
		`<s:Body><u:`+action+`Response xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">`+
		inner+`</u:`+action+`Response></s:Body></s:Envelope>`)
}

func writeFault(w http.ResponseWriter, code int, desc string) {
	w.Header().Set("Content-Type", "text/xml")
	w.WriteHeader(http.StatusInternalServerError)
	io.WriteString(w, `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">`+
		`<s:Body><s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring>`+
		`<detail><UPnPError xmlns="urn:schemas-upnp-org:control-1-0">`+
		`<errorCode>`+strconv.Itoa(code)+`</errorCode><errorDescription>`+desc+`</errorDescription>`+
		`</UPnPError></detail></s:Fault></s:Body></s:Envelope>`)
}

func TestUPnPDescribeFindsNestedRelativeControlURL(t *testing.T) {
	f := newFakeIGD(t)
	g, err := describeIGD(context.Background(), &http.Client{Timeout: 5 * time.Second}, f.location)
	if err != nil {
		t.Fatalf("describeIGD: %v", err)
	}
	if g.serviceType != "urn:schemas-upnp-org:service:WANIPConnection:1" {
		t.Errorf("service type = %q", g.serviceType)
	}
	if g.controlURL != f.srv.URL+"/ctl/IPConn" {
		t.Errorf("control URL = %q, want it resolved against the description URL", g.controlURL)
	}
}

// A device description that points the control URL at another host (a blind
// SSRF if it were honored) is refused: the control endpoint must be on the same
// host the description was fetched from.
func TestUPnPRejectsCrossHostControlURL(t *testing.T) {
	desc := `<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
        <controlURL>http://169.254.169.254/latest/meta-data</controlURL>
      </service>
    </serviceList>
  </device>
</root>`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/xml")
		io.WriteString(w, desc)
	}))
	defer srv.Close()

	_, err := describeIGD(context.Background(), &http.Client{Timeout: 5 * time.Second}, srv.URL+"/rootDesc.xml")
	if err == nil {
		t.Fatal("a control URL on another host was accepted; SSRF")
	}
	if !strings.Contains(err.Error(), "not the gateway") {
		t.Errorf("error = %v, want it to name the host mismatch", err)
	}
}

// A redirect from the control URL is the one way around the host pin: a 307 would
// re-send the POST and its body wherever it pointed. It is not followed.
func TestUPnPDoesNotFollowRedirects(t *testing.T) {
	var reached bool
	elsewhere := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { reached = true }))
	defer elsewhere.Close()

	desc := `<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>
	  <serviceList><service>
	    <serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType>
	    <controlURL>/ctl</controlURL>
	  </service></serviceList></device></root>`
	mux := http.NewServeMux()
	mux.HandleFunc("/rootDesc.xml", func(w http.ResponseWriter, _ *http.Request) { io.WriteString(w, desc) })
	mux.HandleFunc("/ctl", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, elsewhere.URL+"/internal", http.StatusTemporaryRedirect)
	})
	igdSrv := httptest.NewServer(mux)
	defer igdSrv.Close()

	_, err := upnpMap(context.Background(), netip.Addr{}, igdSrv.URL+"/rootDesc.xml",
		netip.MustParseAddr("192.168.1.50"), TCP, 8080, 8099, time.Hour)
	if err == nil {
		t.Error("a redirected control request was reported as success")
	}
	if reached {
		t.Error("the redirect was followed to another host")
	}
}

// With the gateway known, only a device on the gateway's own address is asked:
// SSDP is answered by anything on the LAN.
func TestUPnPIsPinnedToTheGateway(t *testing.T) {
	f := newFakeIGD(t) // listens on 127.0.0.1
	_, err := upnpMap(context.Background(), netip.MustParseAddr("192.168.1.1"), f.location,
		netip.MustParseAddr("192.168.1.50"), TCP, 8080, 8099, time.Hour)
	if err == nil || !strings.Contains(err.Error(), "not on the gateway") {
		t.Errorf("a device off the gateway was used: err = %v", err)
	}
	if _, err := upnpMap(context.Background(), netip.MustParseAddr("127.0.0.1"), f.location,
		netip.MustParseAddr("192.168.1.50"), TCP, 8080, 8099, time.Hour); err != nil {
		t.Errorf("the device on the gateway was refused: %v", err)
	}
}

func TestUPnPMapSendsTheMappingAndReadsTheWANIP(t *testing.T) {
	f := newFakeIGD(t)
	client := netip.MustParseAddr("192.168.1.50")

	m, err := upnpMap(context.Background(), netip.MustParseAddr("127.0.0.1"), f.location, client, TCP, 8080, 8099, 2*time.Hour)
	if err != nil {
		t.Fatalf("upnpMap: %v", err)
	}
	if m.Method != "UPnP" {
		t.Errorf("method = %q", m.Method)
	}
	if m.ExternalPort != 8099 {
		t.Errorf("external port = %d", m.ExternalPort)
	}
	if m.ExternalIP != netip.MustParseAddr("198.51.100.9") {
		t.Errorf("external IP = %v", m.ExternalIP)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.lastClient != "192.168.1.50" {
		t.Errorf("internal client sent = %q, want the host LAN address", f.lastClient)
	}
	if f.lastExtPort != "8099" {
		t.Errorf("external port sent = %q", f.lastExtPort)
	}
	if f.lastLease != "7200" {
		t.Errorf("lease sent = %q, want 7200 seconds", f.lastLease)
	}
}

// A router that supports only permanent leases (error 725) is retried with a
// zero lease rather than failing.
func TestUPnPRetriesWithPermanentLease(t *testing.T) {
	f := newFakeIGD(t)
	f.permanentOnly = true
	client := netip.MustParseAddr("192.168.1.50")

	m, err := upnpMap(context.Background(), netip.MustParseAddr("127.0.0.1"), f.location, client, TCP, 8080, 8099, time.Hour)
	if err != nil {
		t.Fatalf("upnpMap: %v", err)
	}
	if m.ExternalPort != 8099 {
		t.Errorf("external port = %d", m.ExternalPort)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.adds != 2 {
		t.Errorf("AddPortMapping called %d times, want 2 (the 725 retry)", f.adds)
	}
	if f.lastLease != "0" {
		t.Errorf("retry lease = %q, want 0 (permanent)", f.lastLease)
	}
}

func TestUPnPMapNeedsAnInternalClient(t *testing.T) {
	f := newFakeIGD(t)
	if _, err := upnpMap(context.Background(), netip.Addr{}, f.location, netip.Addr{}, TCP, 8080, 8099, time.Hour); err == nil {
		t.Fatal("mapping without an internal client was allowed")
	}
}

func TestUPnPDeleteRemovesTheMapping(t *testing.T) {
	f := newFakeIGD(t)
	client := netip.MustParseAddr("192.168.1.50")
	m, err := upnpMap(context.Background(), netip.MustParseAddr("127.0.0.1"), f.location, client, TCP, 8080, 8099, time.Hour)
	if err != nil {
		t.Fatalf("upnpMap: %v", err)
	}
	if err := unmapTarget(context.Background(), target{}, m, TCP, 8080); err != nil {
		t.Fatalf("unmapTarget: %v", err)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.deletes != 1 {
		t.Errorf("DeletePortMapping called %d times, want 1", f.deletes)
	}
}

// With a UPnP location and internal client, mapTarget falls all
// the way through to UPnP - the fallback-of-last-resort path.
func TestMapTargetFallsThroughToUPnP(t *testing.T) {
	f := newFakeIGD(t)
	t2 := target{
		gateway:        netip.MustParseAddrPort("127.0.0.1:9"),
		internalClient: netip.MustParseAddr("192.168.1.50"),
		upnpLocation:   f.location,
	}
	m, err := mapTarget(context.Background(), t2, TCP, 8080, 8099, time.Hour, Mapping{})
	if err != nil {
		t.Fatalf("mapTarget: %v", err)
	}
	if m.Method != "UPnP" {
		t.Errorf("method = %q, want UPnP", m.Method)
	}
}

// A router answers an M-SEARCH sent straight to it - the search that still
// works from inside the bridged container, where multicast never leaves
// Docker's network. The fake here only answers unicast, on loopback.
func TestUnicastSearchFindsTheRoutersDescription(t *testing.T) {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer conn.Close()
	go func() {
		buf := make([]byte, 2048)
		for {
			n, from, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if !strings.HasPrefix(string(buf[:n]), "M-SEARCH") {
				continue
			}
			reply := "HTTP/1.1 200 OK\r\nCache-Control: max-age=1900\r\n" +
				"Location: http://192.168.0.1:80/RootDevice.xml\r\n" +
				"ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
			_, _ = conn.WriteToUDP([]byte(reply), from)
		}
	}()

	found, err := ssdpSearchAt(context.Background(), conn.LocalAddr().String(), 500*time.Millisecond)
	if err != nil {
		t.Fatalf("ssdpSearchAt: %v", err)
	}
	if len(found) != 1 || found[0] != "http://192.168.0.1:80/RootDevice.xml" {
		t.Errorf("found %q, want the router's one description URL", found)
	}
}

func TestGuessGateway(t *testing.T) {
	cases := map[string]string{
		"192.168.0.50": "192.168.0.1",
		"10.0.4.200":   "10.0.4.1",
		"172.20.9.9":   "172.20.9.1",
		"192.168.1.1":  "", // this host is the .1
		"81.2.69.160":  "", // public: no LAN to guess within
		"fd00::5":      "", // no IPv6 guesses
	}
	for in, want := range cases {
		got := GuessGateway(netip.MustParseAddr(in))
		if want == "" {
			if got.IsValid() {
				t.Errorf("GuessGateway(%s) = %s, want no guess", in, got)
			}
			continue
		}
		if got.String() != want {
			t.Errorf("GuessGateway(%s) = %s, want %s", in, got, want)
		}
	}
}

// The development machine's router, exactly: silent on PCP and NAT-PMP, and
// answering UPnP. Before each UDP method had its own budget, PCP's
// retransmissions spent the whole attempt's deadline and UPnP never ran. Here
// the attempt's deadline is far shorter than PCP would wait on its own, so this
// fails unless PCP and NAT-PMP give way in time.
func TestSilentPCPAndNATPMPLeaveTimeForUPnP(t *testing.T) {
	saved := udpMethodBudget
	udpMethodBudget = 150 * time.Millisecond
	t.Cleanup(func() { udpMethodBudget = saved })

	gw := newFakeGateway(t)
	gw.set(func(g *fakeGateway) { g.pcp = false; g.pmp = false })
	igd := newFakeIGD(t)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	m, err := mapTarget(ctx, target{
		gateway:        gw.addr,
		internalClient: netip.MustParseAddr("192.168.1.50"),
		upnpLocation:   igd.location,
	}, TCP, 8080, 8099, time.Hour, Mapping{})
	if err != nil {
		t.Fatalf("mapTarget: %v", err)
	}
	if m.Method != "UPnP" {
		t.Errorf("method = %q, want UPnP", m.Method)
	}
}

// A second server in the house holds the usual outside port: the router says
// 718, and the Maintainer asks for the ports above it in turn, then keeps
// asking for the one it was given (the owner's asking, 2026-10-12).
func TestATakenPortFallsBackToTheNextOne(t *testing.T) {
	old := udpMethodBudget
	udpMethodBudget = 50 * time.Millisecond
	defer func() { udpMethodBudget = old }()
	f := newFakeIGD(t)
	f.taken = map[string]bool{"8099": true, "8100": true}
	mt := &Maintainer{
		Gateway: netip.MustParseAddr("127.0.0.1"), testServer: netip.MustParseAddrPort("127.0.0.1:9"),
		Proto: TCP, InternalPort: 8099, ExternalPort: 8099, FallbackPorts: 10,
		InternalClient: netip.MustParseAddr("192.168.1.50"), UPnPLocation: f.location,
	}
	m, err := mt.EnsureNow(context.Background())
	if err != nil {
		t.Fatalf("EnsureNow: %v", err)
	}
	if m.ExternalPort != 8101 || mt.OutsidePort() != 8101 {
		t.Fatalf("outside port = %d (%d), want 8101", m.ExternalPort, mt.OutsidePort())
	}
	// A refresh asks for 8101 straight away, not the taken ones again.
	f.mu.Lock()
	f.adds = 0
	f.mu.Unlock()
	if _, err := mt.EnsureNow(context.Background()); err != nil {
		t.Fatalf("refresh: %v", err)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.adds != 1 || f.lastExtPort != "8101" {
		t.Errorf("refresh made %d adds, last port %s; want one, for 8101", f.adds, f.lastExtPort)
	}
}

// With every port up to the limit taken, it says so rather than going on.
func TestEveryFallbackPortTaken(t *testing.T) {
	old := udpMethodBudget
	udpMethodBudget = 50 * time.Millisecond
	defer func() { udpMethodBudget = old }()
	f := newFakeIGD(t)
	f.taken = map[string]bool{"8099": true, "8100": true, "8101": true}
	mt := &Maintainer{
		Gateway: netip.MustParseAddr("127.0.0.1"), testServer: netip.MustParseAddrPort("127.0.0.1:9"),
		Proto: TCP, InternalPort: 8099, ExternalPort: 8099, FallbackPorts: 2,
		InternalClient: netip.MustParseAddr("192.168.1.50"), UPnPLocation: f.location,
	}
	if _, err := mt.EnsureNow(context.Background()); !errors.Is(err, ErrPortTaken) {
		t.Fatalf("err = %v, want ErrPortTaken", err)
	}
}
