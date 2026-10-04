package immich

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// photoFake answers people, cities and metadata searches in the shapes Immich
// 3.2.2 was seen to answer them, and records every metadata search.
type photoFake struct {
	mu       sync.Mutex
	searches []map[string]any
	renamed  map[string]string
	created  map[string]any
}

const (
	albumA = "11111111-1111-1111-1111-111111111111"
	albumB = "22222222-2222-2222-2222-222222222222"
	photoX = "33333333-3333-3333-3333-333333333333"
	photoY = "44444444-4444-4444-4444-444444444444"
)

func (f *photoFake) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	raw, _ := io.ReadAll(r.Body)
	var body map[string]any
	_ = json.Unmarshal(raw, &body)
	switch {
	case r.URL.Path == "/api/people" && r.Method == http.MethodGet:
		if r.URL.Query().Get("page") == "1" {
			json.NewEncoder(w).Encode(map[string]any{"hasNextPage": true, "people": []map[string]any{
				{"id": "p1", "name": "Ada", "isHidden": false}, {"id": "p2", "name": "", "isHidden": true},
			}})
			return
		}
		json.NewEncoder(w).Encode(map[string]any{"hasNextPage": false, "people": []map[string]any{{"id": "p3", "name": ""}}})
	case strings.HasPrefix(r.URL.Path, "/api/people/") && r.Method == http.MethodPut:
		f.renamed[strings.TrimPrefix(r.URL.Path, "/api/people/")] = body["name"].(string)
		w.Write([]byte(`{}`))
	case r.URL.Path == "/api/search/cities":
		json.NewEncoder(w).Encode([]map[string]any{
			{"id": "c2", "exifInfo": map[string]any{"city": "Springfield", "state": "Oregon", "country": "United States of America"}},
			{"id": "c1", "exifInfo": map[string]any{"city": "Riverside", "state": "Oregon", "country": "United States of America"}},
			{"id": "c0", "exifInfo": nil},
		})
	case r.URL.Path == "/api/timeline/bucket":
		// Two September evenings in Mountain Time (UTC-6): the second is already
		// 1 October in UTC. And one with no offset given.
		json.NewEncoder(w).Encode(map[string]any{
			"id":               []string{"e1", "e2", "e3"},
			"isImage":          []bool{true, true, true},
			"isTrashed":        []bool{false, false, false},
			"fileCreatedAt":    []string{"2026-09-29T20:00:00.000Z", "2026-10-01T02:30:00.000Z", "2026-09-15T12:00:00.000Z"},
			"localOffsetHours": []float64{-6, -6},
		})
	case r.URL.Path == "/api/albums" && r.Method == http.MethodGet:
		json.NewEncoder(w).Encode([]map[string]any{
			{"id": albumA, "albumName": "Beach", "assetCount": 2, "albumThumbnailAssetId": photoX, "lastModifiedAssetTimestamp": "2026-08-01T10:00:00.000Z"},
			{"id": albumB, "albumName": "Birthday", "assetCount": 1, "albumThumbnailAssetId": nil, "lastModifiedAssetTimestamp": "2026-09-01T10:00:00.000Z"},
		})
	case r.URL.Path == "/api/albums" && r.Method == http.MethodPost:
		f.created = body
		json.NewEncoder(w).Encode(map[string]any{"id": albumA, "albumName": body["albumName"], "assetCount": 1})
	case r.URL.Path == "/api/albums/"+albumA+"/assets" && r.Method == http.MethodPut:
		json.NewEncoder(w).Encode([]map[string]any{{"id": photoX, "success": true}, {"id": photoY, "success": false, "error": "duplicate"}})
	case r.URL.Path == "/api/search/metadata":
		f.searches = append(f.searches, body)
		items := []asset{}
		// Only 2023 has photos from the day asked about.
		if after, _ := body["takenAfter"].(string); after == "" || strings.HasPrefix(after, "2023-") {
			items = append(items, asset{ID: "x1", Type: "IMAGE", OriginalFileName: "a.jpg", LocalDateTime: "2023-06-01T10:00:00.000Z"})
		}
		json.NewEncoder(w).Encode(map[string]any{"assets": map[string]any{"items": items, "nextPage": nil}})
	default:
		http.NotFound(w, r)
	}
}

func photoSource(t *testing.T) (*Source, *photoFake) {
	t.Helper()
	f := &photoFake{renamed: map[string]string{}}
	srv := httptest.NewServer(f)
	t.Cleanup(srv.Close)
	s, err := New(Config{ID: "immich", BaseURL: srv.URL, APIKey: "k3y", LibraryID: "lib-1", Timeout: 5 * time.Second})
	if err != nil {
		t.Fatal(err)
	}
	return s, f
}

func TestPeopleArePagedHiddenLeftOutFacesAsArt(t *testing.T) {
	s, _ := photoSource(t)
	people, err := s.People(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(people) != 2 || people[0].ID != "p1" || people[0].Name != "Ada" || people[1].ID != "p3" {
		t.Fatalf("people = %+v, want p1 (Ada) and p3, without the hidden p2", people)
	}
	target, err := s.ArtTarget(context.Background(), people[0].ArtID)
	if err != nil || !strings.HasSuffix(strings.Split(target.URL, "?")[0], "/api/people/p1/thumbnail") {
		t.Errorf("face art = %q, %v", target.URL, err)
	}
}

func TestPersonPhotosAreThisLibraryNewestFirst(t *testing.T) {
	s, f := photoSource(t)
	if _, err := s.PersonPhotos(context.Background(), "p1", 50); err != nil {
		t.Fatal(err)
	}
	got := f.searches[0]
	if ids, _ := got["personIds"].([]any); len(ids) != 1 || ids[0] != "p1" || got["libraryId"] != "lib-1" || got["order"] != "desc" {
		t.Errorf("search = %v", got)
	}
}

func TestNamingAPersonPutsTheName(t *testing.T) {
	s, f := photoSource(t)
	if err := s.NamePerson(context.Background(), "p3", "Grace"); err != nil {
		t.Fatal(err)
	}
	if f.renamed["p3"] != "Grace" {
		t.Errorf("renamed = %v", f.renamed)
	}
}

func TestPlacesAreTownsWithTheirStateAndCountry(t *testing.T) {
	s, f := photoSource(t)
	places, err := s.Places(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(places) != 2 || places[0].Name != "Riverside" || places[0].Subtitle != "Oregon, United States of America" || places[0].ArtID != "c1" {
		t.Fatalf("places = %+v, want Riverside then Springfield", places)
	}
	if _, err := s.PlacePhotos(context.Background(), places[1].ID, 10); err != nil {
		t.Fatal(err)
	}
	got := f.searches[0]
	if got["city"] != "Springfield" || got["state"] != "Oregon" || got["country"] != "United States of America" {
		t.Errorf("place search = %v", got)
	}
}

func TestOnThisDayAsksEachEarlierYearAndKeepsTheOnesWithPhotos(t *testing.T) {
	s, f := photoSource(t)
	days, err := s.OnThisDay(context.Background(), time.Date(2026, 6, 1, 15, 0, 0, 0, time.UTC), 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(days) != 1 || days[0].Year != 2023 || len(days[0].Items) != 1 {
		t.Fatalf("days = %+v, want only 2023", days)
	}
	if len(f.searches) != onThisDayYears {
		t.Errorf("%d searches, want one per year (%d)", len(f.searches), onThisDayYears)
	}
	for _, q := range f.searches {
		if after := q["takenAfter"].(string); !strings.Contains(after, "-06-01T00:00:00") {
			t.Errorf("takenAfter = %s, want 1 June at midnight", after)
		}
	}
	// 29 February is only asked of leap years.
	s2, f2 := photoSource(t)
	if _, err := s2.OnThisDay(context.Background(), time.Date(2028, 2, 29, 0, 0, 0, 0, time.UTC), 10); err != nil {
		t.Fatal(err)
	}
	for _, q := range f2.searches {
		if !strings.Contains(q["takenAfter"].(string), "-02-29T") {
			t.Errorf("asked %s for 29 February", q["takenAfter"])
		}
	}
}

func TestATimelinePhotoIsDatedByItsOwnClock(t *testing.T) {
	s, _ := photoSource(t)
	items, err := s.MonthPhotos(context.Background(), "2026-09")
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]string{}
	for _, it := range items {
		got[it.ID] = it.Extra["taken"]
	}
	want := map[string]string{"e1": "2026-09-29T14:00:00", "e2": "2026-09-30T20:30:00", "e3": "2026-09-15T12:00:00"}
	for id, w := range want {
		if got[id] != w {
			t.Errorf("%s taken %q, want %q (its local time)", id, got[id], w)
		}
	}
	if len(items) != 3 || items[0].ID != "e2" {
		t.Errorf("order = %v, want the evening of 30 September first", items)
	}
}

func TestAlbumsAreTheBackendsOwn(t *testing.T) {
	s, f := photoSource(t)
	ctx := context.Background()
	albums, err := s.Albums(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if len(albums) != 2 || albums[0].Name != "Birthday" || albums[1].ArtID != photoX || albums[1].Count != 2 {
		t.Fatalf("albums = %+v, want Birthday (newest) then Beach with its cover", albums)
	}
	if _, err := s.AlbumPhotos(ctx, albumA, 100); err != nil {
		t.Fatal(err)
	}
	got := f.searches[len(f.searches)-1]
	if ids, _ := got["albumIds"].([]any); len(ids) != 1 || ids[0] != albumA {
		t.Errorf("album search %v, want albumIds [%s]", got, albumA)
	}
	if _, has := got["libraryId"]; has {
		t.Errorf("album search %v keeps the library filter; an album shared later holds another's photos", got)
	}
	al, err := s.CreateAlbum(ctx, "Summer", []string{photoX})
	if err != nil || al.ID != albumA || f.created["albumName"] != "Summer" {
		t.Fatalf("created %+v (%v), sent %v", al, err, f.created)
	}
	n, err := s.AddToAlbum(ctx, albumA, []string{photoX, photoY})
	if err != nil || n != 1 {
		t.Errorf("added %d (%v), want 1: one was in already", n, err)
	}
	if _, err := s.AddToAlbum(ctx, "../../api/users", []string{photoX}); err == nil {
		t.Error("an album id that is a path was taken")
	}
	if _, err := s.CreateAlbum(ctx, "x", []string{"not-an-id"}); err == nil {
		t.Error("a photo id that is not one was taken")
	}
}
