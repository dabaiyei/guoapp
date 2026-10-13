package core

import (
	"net/url"
	"strings"
	"testing"
)

func mustParseURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	parsed, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse %q: %v", raw, err)
	}
	return parsed
}

func castDescriptionFor(t *testing.T, body, location string) nativeCastDevice {
	t.Helper()
	device, ok := nativeCastParseDescription([]byte(body), location)
	if !ok {
		t.Fatalf("description not parsed: %s", body)
	}
	return device
}

func TestNativeSSDPLocationParsesCaseInsensitiveHeader(t *testing.T) {
	payload := "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nlocation: http://192.168.1.9:49152/desc.xml\r\nST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n"
	if got := nativeSSDPLocation(payload); got != "http://192.168.1.9:49152/desc.xml" {
		t.Fatalf("location = %q", got)
	}
}

func TestNativeSSDPLocationRejectsPayloadWithoutHeader(t *testing.T) {
	if got := nativeSSDPLocation("HTTP/1.1 200 OK\r\nST: x\r\n"); got != "" {
		t.Fatalf("expected empty location, got %q", got)
	}
}

func TestNativeCastTargetFormatsHoursMinutesSeconds(t *testing.T) {
	cases := []struct {
		input int64
		want  string
	}{
		{0, "00:00:00"},
		{1000, "00:00:01"},
		{61000, "00:01:01"},
		{3661000, "01:01:01"},
		{-5000, "00:00:00"},
	}
	for _, item := range cases {
		if got := nativeCastTarget(item.input); got != item.want {
			t.Fatalf("nativeCastTarget(%d) = %q, want %q", item.input, got, item.want)
		}
	}
}

func TestNativeCastMillisecondsParsesRendererTime(t *testing.T) {
	cases := []struct {
		input string
		want  int64
	}{
		{"00:00:00", 0},
		{"00:01:30", 90000},
		{"01:00:00", 3600000},
		{"00:01:30.2500000", 90000},
		{"", 0},
		{"not-a-time", 0},
		{"99", 99000},
	}
	for _, item := range cases {
		if got := nativeCastMilliseconds(item.input); got != item.want {
			t.Fatalf("nativeCastMilliseconds(%q) = %d, want %d", item.input, got, item.want)
		}
	}
}

func TestNativeCastMetadataEscapesTitleAndCarriesAddress(t *testing.T) {
	metadata := nativeCastMetadata(`剧名 & <测试>`, "http://192.168.1.5:8080/token/asset.m3u8")
	for _, want := range []string{"剧名 &amp; &lt;测试&gt;", "object.item.videoItem", "application/vnd.apple.mpegurl", "http://192.168.1.5:8080/token/asset.m3u8"} {
		if !strings.Contains(metadata, want) {
			t.Fatalf("metadata missing %q: %s", want, metadata)
		}
	}
	if strings.Contains(metadata, "<测试>") {
		t.Fatalf("metadata did not escape angle brackets: %s", metadata)
	}
}

func TestNativeCastContentTypeDetectsPlaylists(t *testing.T) {
	cases := map[string]string{
		"http://host/a/b/index.m3u8":   "application/vnd.apple.mpegurl",
		"http://host/a/b/index.m3u8?x": "application/vnd.apple.mpegurl",
		"http://host/a/b/clip.mp4":     "video/mp4",
		"http://host/a/b/clip.ts":      "video/mp4",
	}
	for input, want := range cases {
		if got := nativeCastContentType(input); got != want {
			t.Fatalf("nativeCastContentType(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestNativeCastUDPAddressAddsDefaultPort(t *testing.T) {
	address := nativeCastUDPAddress("192.168.1.7")
	if address == nil || address.Port != 1900 || address.IP.String() != "192.168.1.7" {
		t.Fatalf("unexpected address: %#v", address)
	}
	explicit := nativeCastUDPAddress("192.168.1.7:1901")
	if explicit == nil || explicit.Port != 1901 {
		t.Fatalf("explicit port not honoured: %#v", explicit)
	}
	if nativeCastUDPAddress("   ") != nil {
		t.Fatalf("blank host should not resolve")
	}
}

func TestNativeCastSubnetTargetsCoversHostRange(t *testing.T) {
	targets := nativeCastSubnetTargets("192.168.1.7")
	if len(targets) != 254 {
		t.Fatalf("expected 254 targets, got %d", len(targets))
	}
	if targets[0].IP.String() != "192.168.1.1" || targets[253].IP.String() != "192.168.1.254" {
		t.Fatalf("unexpected range bounds: %s .. %s", targets[0].IP, targets[253].IP)
	}
	if nativeCastSubnetTargets("not-an-ip") != nil {
		t.Fatalf("invalid host should yield no targets")
	}
}

func TestNativeCastResolveURLHandlesRelativeControlPaths(t *testing.T) {
	base := mustParseURL(t, "http://192.168.1.9:49152/description.xml")
	if got := nativeCastResolveURL(base, "/upnp/control/AVTransport1"); got != "http://192.168.1.9:49152/upnp/control/AVTransport1" {
		t.Fatalf("resolved = %q", got)
	}
	if got := nativeCastResolveURL(base, "http://other/control"); got != "http://other/control" {
		t.Fatalf("absolute url = %q", got)
	}
	if got := nativeCastResolveURL(base, "  "); got != "" {
		t.Fatalf("blank reference = %q", got)
	}
}

func TestNativeCastPickMediaMatchesRequestedQuality(t *testing.T) {
	choice := nativePlaybackChoice{
		index: 0,
		media: []providerMedia{
			{URL: "https://host/1080.m3u8", Quality: 1080},
			{URL: "https://host/720.m3u8", Quality: 720},
			{URL: "https://host/480.m3u8", Quality: 480},
		},
	}
	if got := nativeCastPickMedia(choice, 720); got.Quality != 720 {
		t.Fatalf("quality 720 picked %d", got.Quality)
	}
	// 0 表示自动：沿用当前线路，不应乱选。
	if got := nativeCastPickMedia(choice, 0); got.Quality != 1080 {
		t.Fatalf("auto picked %d", got.Quality)
	}
	// 线路里没有该清晰度时回落到当前线路，而不是 panic。
	if got := nativeCastPickMedia(choice, 2160); got.Quality != 1080 {
		t.Fatalf("missing quality picked %d", got.Quality)
	}
}

func TestNativeCastDescribePicksAVTransportFromServiceList(t *testing.T) {
	body := `<?xml version="1.0"?><root><device>
<friendlyName>客厅电视</friendlyName><modelName>MiTV</modelName>
<serviceList>
<service><serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType><controlURL>/rc</controlURL></service>
<service><serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType><controlURL>/av</controlURL></service>
</serviceList></device></root>`
	description := castDescriptionFor(t, body, "http://192.168.1.9:49152/desc.xml")
	if description.Name != "客厅电视" || description.Model != "MiTV" {
		t.Fatalf("unexpected identity: %#v", description)
	}
	if description.ControlURL != "http://192.168.1.9:49152/av" {
		t.Fatalf("control url = %q", description.ControlURL)
	}
	if !strings.Contains(description.ServiceType, "AVTransport") {
		t.Fatalf("service type = %q", description.ServiceType)
	}
	if description.RenderingControlURL != "http://192.168.1.9:49152/rc" {
		t.Fatalf("rendering url = %q", description.RenderingControlURL)
	}
}

// 播完判定：电视走到片尾多为 STOPPED，且位置接近总时长。
func TestNativeCastEndedDetection(t *testing.T) {
	cases := []struct {
		state       string
		positionMS  int64
		durationMS  int64
		want        bool
		description string
	}{
		{"STOPPED", 123500, 123500, true, "停在片尾"},
		{"STOPPED", 121000, 123500, true, "距片尾 2.5s 视作播完"},
		{"STOPPED", 120000, 123500, false, "距片尾 3.5s 不算播完"},
		{"STOPPED", 60000, 123500, false, "中途停止不算播完"},
		{"PLAYING", 123500, 123500, false, "播放中不算播完"},
		{"PAUSED_PLAYBACK", 123500, 123500, false, "暂停不算播完"},
		{"STOPPED", 0, 0, false, "时长未知时不算播完"},
		{"", 123500, 123500, false, "状态未知时不算播完"},
	}
	for _, item := range cases {
		if got := nativeCastEnded(item.state, item.positionMS, item.durationMS); got != item.want {
			t.Fatalf("%s: ended=%v want %v", item.description, got, item.want)
		}
	}
}
