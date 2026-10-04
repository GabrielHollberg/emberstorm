package immich

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"sort"

	"github.com/GabrielHollberg/soundstorm/internal/httpx"
	"github.com/GabrielHollberg/soundstorm/internal/media"
	"github.com/GabrielHollberg/soundstorm/internal/source"
)

// Albums are Immich's own, each person's in their own photo account - so
// they are as private as the photos, and Immich's album sharing is there for
// sharing one later. Checked against 3.2.2's own code: GET /api/albums,
// POST /api/albums {albumName, assetIds}, PUT and DELETE
// /api/albums/{id}/assets {ids}, PATCH and DELETE /api/albums/{id}; an
// album's photos are a metadata search by albumIds.

var albumIDRE = regexp.MustCompile(`^[0-9a-fA-F-]{36}$`)

type immichAlbum struct {
	ID                         string  `json:"id"`
	AlbumName                  string  `json:"albumName"`
	AssetCount                 int     `json:"assetCount"`
	AlbumThumbnailAssetID      *string `json:"albumThumbnailAssetId"`
	StartDate                  string  `json:"startDate"`
	EndDate                    string  `json:"endDate"`
	LastModifiedAssetTimestamp string  `json:"lastModifiedAssetTimestamp"`
	UpdatedAt                  string  `json:"updatedAt"`
}

func (a immichAlbum) out() source.PhotoAlbum {
	al := source.PhotoAlbum{ID: a.ID, Name: a.AlbumName, Count: a.AssetCount, Start: a.StartDate, End: a.EndDate,
		Updated: a.LastModifiedAssetTimestamp}
	if al.Updated == "" {
		al.Updated = a.UpdatedAt
	}
	if a.AlbumThumbnailAssetID != nil {
		al.ArtID = *a.AlbumThumbnailAssetID
	}
	return al
}

func validIDs(ids []string) error {
	for _, id := range ids {
		if !albumIDRE.MatchString(id) {
			return fmt.Errorf("not a photo id: %q", id)
		}
	}
	return nil
}

// do is a request with a JSON body as the person asking.
func (s *Source) do(ctx context.Context, method, path string, body any, out any) error {
	h, _, err := s.as(ctx)
	if err != nil {
		return err
	}
	resp, err := s.http.Do(ctx, httpx.Request{Method: method, Path: path, Body: body, Headers: h})
	if err != nil {
		return fmt.Errorf("immich %q: %w", s.id, err)
	}
	if err := resp.Err(); err != nil {
		return err
	}
	if out != nil {
		return resp.JSON(out)
	}
	return nil
}

// Albums is this person's albums, the most recently added to first.
func (s *Source) Albums(ctx context.Context) ([]source.PhotoAlbum, error) {
	var got []immichAlbum
	if err := s.getJSON(ctx, "/api/albums", nil, &got); err != nil {
		return nil, err
	}
	out := make([]source.PhotoAlbum, 0, len(got))
	for _, a := range got {
		out = append(out, a.out())
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Updated != out[j].Updated {
			return out[i].Updated > out[j].Updated
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}

// AlbumPhotos is an album's photos and videos, newest first. Not limited to
// the person's own library: an album shared with them holds another's.
func (s *Source) AlbumPhotos(ctx context.Context, id string, limit int) ([]media.Item, error) {
	if !albumIDRE.MatchString(id) {
		return nil, fmt.Errorf("no such album")
	}
	return s.photos(ctx, map[string]any{"albumIds": []string{id}, "libraryId": nil}, limit)
}

func (s *Source) CreateAlbum(ctx context.Context, name string, itemIDs []string) (source.PhotoAlbum, error) {
	if err := validIDs(itemIDs); err != nil {
		return source.PhotoAlbum{}, err
	}
	var got immichAlbum
	body := map[string]any{"albumName": name, "assetIds": itemIDs}
	if err := s.do(ctx, http.MethodPost, "/api/albums", body, &got); err != nil {
		return source.PhotoAlbum{}, err
	}
	return got.out(), nil
}

type bulkResult struct {
	ID      string `json:"id"`
	Success bool   `json:"success"`
}

func countDone(rs []bulkResult) int {
	n := 0
	for _, r := range rs {
		if r.Success {
			n++
		}
	}
	return n
}

func (s *Source) AddToAlbum(ctx context.Context, id string, itemIDs []string) (int, error) {
	if !albumIDRE.MatchString(id) {
		return 0, fmt.Errorf("no such album")
	}
	if err := validIDs(itemIDs); err != nil {
		return 0, err
	}
	var got []bulkResult
	if err := s.do(ctx, http.MethodPut, "/api/albums/"+url.PathEscape(id)+"/assets", map[string]any{"ids": itemIDs}, &got); err != nil {
		return 0, err
	}
	return countDone(got), nil
}

func (s *Source) RemoveFromAlbum(ctx context.Context, id string, itemIDs []string) (int, error) {
	if !albumIDRE.MatchString(id) {
		return 0, fmt.Errorf("no such album")
	}
	if err := validIDs(itemIDs); err != nil {
		return 0, err
	}
	var got []bulkResult
	if err := s.do(ctx, http.MethodDelete, "/api/albums/"+url.PathEscape(id)+"/assets", map[string]any{"ids": itemIDs}, &got); err != nil {
		return 0, err
	}
	return countDone(got), nil
}

func (s *Source) RenameAlbum(ctx context.Context, id, name string) error {
	if !albumIDRE.MatchString(id) {
		return fmt.Errorf("no such album")
	}
	return s.do(ctx, http.MethodPatch, "/api/albums/"+url.PathEscape(id), map[string]any{"albumName": name}, nil)
}

// DeleteAlbum deletes the album only: its photos stay where they are.
func (s *Source) DeleteAlbum(ctx context.Context, id string) error {
	if !albumIDRE.MatchString(id) {
		return fmt.Errorf("no such album")
	}
	return s.do(ctx, http.MethodDelete, "/api/albums/"+url.PathEscape(id), nil, nil)
}
