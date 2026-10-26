//go:build !win32

package main

import (
	"reflect"
	"testing"
)

// win32Table is false on every tag but win32: the shared table's frozen
// X11 assertions apply.
const win32Table = false

// On a host that removes no chord, the layer table is the shared one as
// written: pruning orphaned layers drops nothing, and the switcher drives
// the quickshell overlay.
func TestLayers_SharedTableUnpruned(t *testing.T) {
	if !reflect.DeepEqual(Layers, sharedLayers(qsOverlayScript)) {
		t.Fatalf("Layers differs from the shared table: %v", sortedLayerNames(Layers))
	}
}
