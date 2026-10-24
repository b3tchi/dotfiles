//go:build phone

package main

import (
	"reflect"
	"testing"

	"hotkeyd/internal/bind"
)

func TestPhoneTable(t *testing.T) {
	var ret *bind.Bind
	for i := range Binds {
		if Binds[i].Chord == "$mod+Return" {
			ret = &Binds[i]
		}
	}
	if ret == nil || !reflect.DeepEqual(ret.Actions, runAction("foot")) {
		t.Fatalf("$mod+Return on the phone = %+v, want run foot", ret)
	}
	for _, mod := range bind.ModResolutions {
		if problems := bind.Validate(Binds, Layers, mod); len(problems) != 0 {
			t.Errorf("Validate(mod=%s): %v", mod, problems)
		}
	}
}
