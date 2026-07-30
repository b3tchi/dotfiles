package main

import "bytes"

// flattenD2SVG detects d2 v0.7.1's outer/inner double-<svg> wrapper shape
// and promotes the inner <svg> — the one that actually holds the diagram's
// shapes/text/paths/mask — to document root, carrying over whichever outer
// attributes the inner tag lacks.
//
// Why: Qt's QtSvg image plugin implements the SVG Tiny 1.2 profile, which
// forbids nested <svg> elements. Fed d2's raw output — an outer
// <svg viewBox="0 0 W H"> wrapping an inner <svg class="d2-..."
// viewBox="..."> that holds everything — QtSvg logs "Skipping a nested svg
// element" and drops the ENTIRE inner content, rendering a blank image
// (dotfiles-o3b7). This transform produces an equivalent single-root
// document: browsers render it identically (the outer's only meaningful
// attributes — xmlns, xmlns:xlink, preserveAspectRatio, data-d2-version —
// are promoted onto the new root, and the inner's viewBox/width/height/class
// — the ones that carry the real content offset — are kept as-is), while
// QtSvg (and any other Tiny-1.2-constrained consumer) can now render it at
// all.
//
// Scope: this only unwraps the OUTERMOST pair. Real d2 boards can have
// their own nested <svg> icons deeper in the content (confirmed against a
// production board, docs/map/d2/01-context.svg) — those are a separate,
// smaller concern this function deliberately does not touch.
//
// If data doesn't match the expected two-<svg> wrapper shape exactly — not
// an svg at all, already flat, malformed/truncated, or an unexpected inner
// structure (e.g. the outer has more than one child) — it is returned
// completely unchanged. This function never panics and never guesses: any
// shape it doesn't recognize passes through untouched.
func flattenD2SVG(data []byte) []byte {
	const openTag = "<svg"
	const closeTag = "</svg>"

	outerStart := indexTagOpen(data, openTag, 0)
	if outerStart < 0 {
		return data // no <svg at all — not our concern (non-svg input)
	}

	outerTagEnd := scanTagEnd(data, outerStart)
	if outerTagEnd < 0 {
		return data // truncated mid-tag — degrade to unchanged
	}
	if data[outerTagEnd-1] == '/' {
		return data // outer svg is self-closing — nothing nested to flatten
	}

	// Immediately after the outer tag (only whitespace allowed in between)
	// must come another <svg — otherwise this isn't d2's pure wrapper shape
	// (e.g. the outer has real content of its own), and we must not guess.
	j := skipSpaceBytes(data, outerTagEnd+1)
	innerStart := indexTagOpen(data, openTag, j)
	if innerStart != j {
		return data
	}

	innerTagEnd := scanTagEnd(data, innerStart)
	if innerTagEnd < 0 {
		return data // truncated mid-tag
	}
	if data[innerTagEnd-1] == '/' {
		return data // inner is self-closing (empty) — nothing to promote into
	}

	// The document must end with the inner's own closing tag immediately
	// followed by the outer's closing tag (only whitespace allowed between
	// or after) — the exact shape d2 emits. Anything else (extra trailing
	// siblings, truncation) means we can't safely identify where the
	// inner's content ends, so we back off unchanged.
	end := len(data)
	for end > 0 && isSpaceByte(data[end-1]) {
		end--
	}
	if end < len(closeTag) || string(data[end-len(closeTag):end]) != closeTag {
		return data
	}
	end -= len(closeTag) // now just past the inner's own closing tag
	for end > 0 && isSpaceByte(data[end-1]) {
		end--
	}
	if end < len(closeTag) || string(data[end-len(closeTag):end]) != closeTag {
		return data
	}
	bodyEnd := end - len(closeTag) // start of the inner's own "</svg>"

	if bodyEnd < innerTagEnd+1 {
		return data // pathological/negative span — never trust it
	}

	outerAttrs := parseSVGAttrs(string(data[outerStart+len(openTag) : outerTagEnd]))
	innerAttrs := parseSVGAttrs(string(data[innerStart+len(openTag) : innerTagEnd]))

	haveInner := make(map[string]bool, len(innerAttrs))
	for _, a := range innerAttrs {
		haveInner[a.name] = true
	}

	var b bytes.Buffer
	b.Grow(len(data))
	b.Write(data[:outerStart]) // preserve any leading bytes (e.g. <?xml ...?>) verbatim
	b.WriteString(openTag)
	for _, a := range innerAttrs {
		b.WriteByte(' ')
		b.WriteString(a.raw)
	}
	for _, a := range outerAttrs {
		if haveInner[a.name] {
			continue // inner's value wins (e.g. viewBox: inner carries the real content offset)
		}
		b.WriteByte(' ')
		b.WriteString(a.raw)
	}
	b.WriteByte('>')
	b.Write(data[innerTagEnd+1 : bodyEnd])
	b.WriteString(closeTag)
	return b.Bytes()
}

// svgAttr holds one parsed attribute, both its bare name (for de-duplication)
// and its raw "name=quote...quote" text (re-emitted verbatim so we never
// have to make a decision about quote style or escaping).
type svgAttr struct {
	name string
	raw  string
}

// parseSVGAttrs parses the attribute list from inside an already-isolated
// tag-header substring (the text between "<svg" and the tag's closing '>'
// or '/'). Malformed fragments are skipped rather than guessed at — a
// best-effort attribute or two lost from a corrupt tag is preferable to a
// panic or a fabricated value.
func parseSVGAttrs(s string) []svgAttr {
	var attrs []svgAttr
	i, n := 0, len(s)
	for i < n {
		for i < n && isSpaceByte(s[i]) {
			i++
		}
		if i >= n {
			break
		}
		if s[i] == '/' {
			break // trailing self-close marker; nothing more to parse
		}

		nameStart := i
		for i < n && s[i] != '=' && !isSpaceByte(s[i]) {
			i++
		}
		name := s[nameStart:i]
		if name == "" {
			i++
			continue
		}

		for i < n && isSpaceByte(s[i]) {
			i++
		}
		if i >= n || s[i] != '=' {
			// attribute with no value — not valid SVG in practice; skip
			// rather than fabricate one.
			continue
		}
		i++ // consume '='
		for i < n && isSpaceByte(s[i]) {
			i++
		}
		if i >= n {
			break
		}

		quote := s[i]
		if quote != '"' && quote != '\'' {
			// unquoted value (not valid XML, but degrade sensibly rather
			// than dropping it): read until whitespace.
			valStart := i
			for i < n && !isSpaceByte(s[i]) {
				i++
			}
			attrs = append(attrs, svgAttr{name: name, raw: name + "=" + s[valStart:i]})
			continue
		}
		i++ // consume opening quote
		valStart := i
		for i < n && s[i] != quote {
			i++
		}
		val := s[valStart:i]
		if i < n {
			i++ // consume closing quote
		}
		attrs = append(attrs, svgAttr{
			name: name,
			raw:  name + "=" + string(quote) + val + string(quote),
		})
	}
	return attrs
}

// indexTagOpen finds the first occurrence of tag (e.g. "<svg") at or after
// from that is a genuine tag boundary — i.e. immediately followed by '>',
// '/', or whitespace, not by more identifier characters (so "<svgfoo" never
// matches "<svg"). Returns -1 if no such boundary occurrence exists.
func indexTagOpen(data []byte, tag string, from int) int {
	if from < 0 || from > len(data) {
		return -1
	}
	for {
		idx := bytes.Index(data[from:], []byte(tag))
		if idx < 0 {
			return -1
		}
		pos := from + idx
		end := pos + len(tag)
		if end >= len(data) {
			return -1
		}
		c := data[end]
		if c == '>' || c == '/' || isSpaceByte(c) {
			return pos
		}
		from = pos + 1
	}
}

// scanTagEnd scans a tag starting at data[start] (which must be '<') for
// its matching unescaped '>', respecting single/double-quoted attribute
// values so a literal '>' inside a quoted value never ends the tag early.
// Returns -1 if the tag never closes before EOF (truncated input).
func scanTagEnd(data []byte, start int) int {
	inSingle, inDouble := false, false
	for i := start; i < len(data); i++ {
		c := data[i]
		switch {
		case c == '\'' && !inDouble:
			inSingle = !inSingle
		case c == '"' && !inSingle:
			inDouble = !inDouble
		case c == '>' && !inSingle && !inDouble:
			return i
		}
	}
	return -1
}

func isSpaceByte(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

func skipSpaceBytes(data []byte, i int) int {
	for i < len(data) && isSpaceByte(data[i]) {
		i++
	}
	return i
}
