package httpapi

import (
	"net/http"
	"strings"
	"testing"
)

// A second box on the network: its label's code typed at emberstorm.local
// reaches the first box. The refusal says which box this is and where to go.
func TestAWrongCodeOnABoxSaysWhichBoxThisIs(t *testing.T) {
	h := newHarness(t)
	h.api.boxUnit = "EM-7K4P-XQ2M"
	resp, body := h.do(t, http.MethodPost, "/api/signup",
		`{"username":"gabriel","password":"a long enough password here","setupCode":"0000-0000-0000-0000-0000"}`)
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("wrong code = %d %s", resp.StatusCode, body)
	}
	if !strings.Contains(string(body), "em-7k4p-xq2m.local") || !strings.Contains(string(body), "back of the box") {
		t.Errorf("the refusal does not say which box this is: %s", body)
	}
}
