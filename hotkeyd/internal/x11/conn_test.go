package x11

import "testing"

func TestParseDisplay(t *testing.T) {
	cases := []struct {
		name       string
		in         string
		wantHost   string
		wantNum    int
		wantScreen int
		wantErr    bool
	}{
		{name: "bare display", in: ":0", wantHost: "", wantNum: 0, wantScreen: 0},
		{name: "display with screen", in: ":10.0", wantHost: "", wantNum: 10, wantScreen: 0},
		{name: "display with nonzero screen", in: ":0.2", wantHost: "", wantNum: 0, wantScreen: 2},
		{name: "hostname prefixed", in: "myhost:1", wantHost: "myhost", wantNum: 1, wantScreen: 0},
		{name: "empty string is invalid", in: "", wantErr: true},
		{name: "missing colon is invalid", in: "0", wantErr: true},
		{name: "non-numeric display is invalid", in: ":abc", wantErr: true},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			host, num, screen, err := ParseDisplay(tc.in)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("ParseDisplay(%q) = nil error, want error", tc.in)
				}
				return
			}
			if err != nil {
				t.Fatalf("ParseDisplay(%q) unexpected error: %v", tc.in, err)
			}
			if host != tc.wantHost || num != tc.wantNum || screen != tc.wantScreen {
				t.Fatalf("ParseDisplay(%q) = (%q, %d, %d), want (%q, %d, %d)",
					tc.in, host, num, screen, tc.wantHost, tc.wantNum, tc.wantScreen)
			}
		})
	}
}
