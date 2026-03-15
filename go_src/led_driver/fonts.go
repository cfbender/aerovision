package main

// font5x7 is a 5-wide by 7-tall bitmap font.
// Each glyph is [7]byte where each byte encodes one row of 5 pixels.
// Bit layout per byte: bit4=leftmost pixel, bit0=rightmost pixel.
// Pixels are stored top-row-first.
//
// Character advance is 6 pixels (5 pixels + 1 pixel spacing).

type glyph [7]byte

// font5x7 maps rune → glyph.
var font5x7 = map[rune]glyph{
	// ── Space ──────────────────────────────────────────────────────────────
	' ': {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00},

	// ── Digits ─────────────────────────────────────────────────────────────
	//     ###
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//     ###
	'0': {0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E},

	//      #
	//     ##
	//      #
	//      #
	//      #
	//      #
	//     ###
	'1': {0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E},

	//     ###
	//    #   #
	//        #
	//      ##
	//     #
	//    #
	//    #####
	'2': {0x0E, 0x11, 0x01, 0x06, 0x08, 0x10, 0x1F},

	//     ###
	//    #   #
	//        #
	//      ##
	//        #
	//    #   #
	//     ###
	'3': {0x0E, 0x11, 0x01, 0x06, 0x01, 0x11, 0x0E},

	//       #
	//      ##
	//     # #
	//    #  #
	//    #####
	//       #
	//       #
	'4': {0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02},

	//    #####
	//    #
	//    ####
	//        #
	//        #
	//    #   #
	//     ###
	'5': {0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E},

	//     ###
	//    #
	//    #
	//    ####
	//    #   #
	//    #   #
	//     ###
	'6': {0x0E, 0x10, 0x10, 0x1E, 0x11, 0x11, 0x0E},

	//    #####
	//        #
	//       #
	//      #
	//     #
	//     #
	//     #
	'7': {0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08},

	//     ###
	//    #   #
	//    #   #
	//     ###
	//    #   #
	//    #   #
	//     ###
	'8': {0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E},

	//     ###
	//    #   #
	//    #   #
	//     ####
	//        #
	//        #
	//     ###
	'9': {0x0E, 0x11, 0x11, 0x0F, 0x01, 0x01, 0x0E},

	// ── Uppercase Letters ──────────────────────────────────────────────────
	//      #
	//     # #
	//    #   #
	//    #####
	//    #   #
	//    #   #
	//    #   #
	'A': {0x04, 0x0A, 0x11, 0x1F, 0x11, 0x11, 0x11},

	//    ####
	//    #   #
	//    #   #
	//    ####
	//    #   #
	//    #   #
	//    ####
	'B': {0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E},

	//     ###
	//    #   #
	//    #
	//    #
	//    #
	//    #   #
	//     ###
	'C': {0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E},

	//    ####
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//    ####
	'D': {0x1E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1E},

	//    #####
	//    #
	//    #
	//    ####
	//    #
	//    #
	//    #####
	'E': {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F},

	//    #####
	//    #
	//    #
	//    ####
	//    #
	//    #
	//    #
	'F': {0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10},

	//     ###
	//    #   #
	//    #
	//    #  ##
	//    #   #
	//    #   #
	//     ####
	'G': {0x0E, 0x11, 0x10, 0x13, 0x11, 0x11, 0x0F},

	//    #   #
	//    #   #
	//    #   #
	//    #####
	//    #   #
	//    #   #
	//    #   #
	'H': {0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11},

	//    #####
	//      #
	//      #
	//      #
	//      #
	//      #
	//    #####
	'I': {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x1F},

	//    #####
	//      #
	//      #
	//      #
	//      #
	//    # #
	//     #
	'J': {0x1F, 0x04, 0x04, 0x04, 0x04, 0x0A, 0x04},

	//    #   #
	//    #  #
	//    # #
	//    ##
	//    # #
	//    #  #
	//    #   #
	'K': {0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11},

	//    #
	//    #
	//    #
	//    #
	//    #
	//    #
	//    #####
	'L': {0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F},

	//    #   #
	//    ## ##
	//    # # #
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	'M': {0x11, 0x1B, 0x15, 0x11, 0x11, 0x11, 0x11},

	//    #   #
	//    ##  #
	//    # # #
	//    #  ##
	//    #   #
	//    #   #
	//    #   #
	'N': {0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11},

	//     ###
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//     ###
	'O': {0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E},

	//    ####
	//    #   #
	//    #   #
	//    ####
	//    #
	//    #
	//    #
	'P': {0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10},

	//     ###
	//    #   #
	//    #   #
	//    #   #
	//    # # #
	//    #  #
	//     ## #
	'Q': {0x0E, 0x11, 0x11, 0x11, 0x15, 0x0A, 0x0D},

	//    ####
	//    #   #
	//    #   #
	//    ####
	//    # #
	//    #  #
	//    #   #
	'R': {0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11},

	//     ###
	//    #   #
	//    #
	//     ###
	//        #
	//    #   #
	//     ###
	'S': {0x0E, 0x11, 0x10, 0x0E, 0x01, 0x11, 0x0E},

	//    #####
	//      #
	//      #
	//      #
	//      #
	//      #
	//      #
	'T': {0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04},

	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//     ###
	'U': {0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E},

	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//     # #
	//      #
	'V': {0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04},

	//    #   #
	//    #   #
	//    #   #
	//    # # #
	//    # # #
	//    ## ##
	//    #   #
	'W': {0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11},

	//    #   #
	//    #   #
	//     # #
	//      #
	//     # #
	//    #   #
	//    #   #
	'X': {0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11},

	//    #   #
	//    #   #
	//     # #
	//      #
	//      #
	//      #
	//      #
	'Y': {0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04},

	//    #####
	//        #
	//       #
	//      #
	//     #
	//    #
	//    #####
	'Z': {0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F},

	// ── Lowercase Letters ──────────────────────────────────────────────────
	//
	//     ###
	//    #   #
	//    # ###
	//    ## #
	//     ## #
	'a': {0x00, 0x00, 0x0E, 0x01, 0x0F, 0x11, 0x0F},

	//    #
	//    #
	//    ####
	//    #   #
	//    #   #
	//    #   #
	//    ####
	'b': {0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x1E},

	//
	//     ###
	//    #   #
	//    #
	//    #
	//    #   #
	//     ###
	'c': {0x00, 0x00, 0x0E, 0x11, 0x10, 0x11, 0x0E},

	//        #
	//        #
	//     ####
	//    #   #
	//    #   #
	//    #   #
	//     ####
	'd': {0x01, 0x01, 0x0F, 0x11, 0x11, 0x11, 0x0F},

	//
	//     ###
	//    #   #
	//    #####
	//    #
	//    #   #
	//     ###
	'e': {0x00, 0x00, 0x0E, 0x11, 0x1F, 0x10, 0x0E},

	//      ##
	//     #  #
	//     #
	//    ####
	//     #
	//     #
	//     #
	'f': {0x03, 0x04, 0x04, 0x0E, 0x04, 0x04, 0x04},

	//
	//     ####
	//    #   #
	//    #   #
	//     ####
	//        #
	//     ###
	'g': {0x00, 0x00, 0x0F, 0x11, 0x11, 0x0F, 0x01},

	//    #
	//    #
	//    ####
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	'h': {0x10, 0x10, 0x1E, 0x11, 0x11, 0x11, 0x11},

	//      #
	//      #
	//      #
	//      #
	//      #
	//      #
	//      #
	'i': {0x04, 0x00, 0x04, 0x04, 0x04, 0x04, 0x04},

	//       #
	//
	//       #
	//       #
	//       #
	//    #  #
	//     ##
	'j': {0x01, 0x00, 0x01, 0x01, 0x01, 0x11, 0x0E},

	//    #
	//    #
	//    #  #
	//    # #
	//    ##
	//    # #
	//    #  #
	'k': {0x10, 0x10, 0x12, 0x14, 0x18, 0x14, 0x12},

	//    ##
	//     #
	//     #
	//     #
	//     #
	//     #
	//    ###
	'l': {0x18, 0x08, 0x08, 0x08, 0x08, 0x08, 0x1C},

	//
	//    ## #
	//    # # #
	//    # # #
	//    #   #
	//    #   #
	//    #   #
	'm': {0x00, 0x00, 0x1A, 0x15, 0x15, 0x11, 0x11},

	//
	//    ####
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	'n': {0x00, 0x00, 0x1E, 0x11, 0x11, 0x11, 0x11},

	//
	//     ###
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//     ###
	'o': {0x00, 0x00, 0x0E, 0x11, 0x11, 0x11, 0x0E},

	//
	//    ####
	//    #   #
	//    #   #
	//    ####
	//    #
	//    #
	'p': {0x00, 0x00, 0x1E, 0x11, 0x11, 0x1E, 0x10},

	//
	//     ####
	//    #   #
	//    #   #
	//     ####
	//        #
	//        #
	'q': {0x00, 0x00, 0x0F, 0x11, 0x11, 0x0F, 0x01},

	//
	//    # ##
	//    ##  #
	//    #
	//    #
	//    #
	//    #
	'r': {0x00, 0x00, 0x0B, 0x14, 0x10, 0x10, 0x10},

	//
	//     ###
	//    #
	//     ###
	//        #
	//    #   #
	//     ###
	's': {0x00, 0x00, 0x0E, 0x10, 0x0E, 0x01, 0x0E},

	//     #
	//    ####
	//     #
	//     #
	//     #
	//     # #
	//      #
	't': {0x04, 0x1F, 0x04, 0x04, 0x04, 0x05, 0x02},

	//
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//    #  ##
	//     ## #
	'u': {0x00, 0x00, 0x11, 0x11, 0x11, 0x13, 0x0D},

	//
	//    #   #
	//    #   #
	//    #   #
	//    #   #
	//     # #
	//      #
	'v': {0x00, 0x00, 0x11, 0x11, 0x11, 0x0A, 0x04},

	//
	//    #   #
	//    #   #
	//    # # #
	//    # # #
	//    ## ##
	//    #   #
	'w': {0x00, 0x00, 0x11, 0x11, 0x15, 0x1B, 0x11},

	//
	//    #   #
	//     # #
	//      #
	//     # #
	//    #   #
	//    #   #
	'x': {0x00, 0x00, 0x11, 0x0A, 0x04, 0x0A, 0x11},

	//
	//    #   #
	//    #   #
	//     # #
	//      #
	//     #
	//    #
	'y': {0x00, 0x00, 0x11, 0x11, 0x0A, 0x04, 0x18},

	//
	//    #####
	//       #
	//      #
	//     #
	//    #
	//    #####
	'z': {0x00, 0x00, 0x1F, 0x02, 0x04, 0x08, 0x1F},

	// ── Symbols ────────────────────────────────────────────────────────────

	//    .
	'.': {0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C},

	//    ,
	',': {0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C, 0x08},

	//    :
	':': {0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00},

	//    -
	'-': {0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00},

	//    +
	'+': {0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00},

	//    >
	'>': {0x10, 0x08, 0x04, 0x02, 0x04, 0x08, 0x10},

	//    <
	'<': {0x01, 0x02, 0x04, 0x08, 0x04, 0x02, 0x01},

	//    /
	'/': {0x01, 0x01, 0x02, 0x04, 0x08, 0x10, 0x10},

	//    !
	'!': {0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04},

	//    ?
	'?': {0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04},

	//    '
	'\'': {0x04, 0x04, 0x08, 0x00, 0x00, 0x00, 0x00},

	//    "
	'"': {0x0A, 0x0A, 0x05, 0x00, 0x00, 0x00, 0x00},

	//    %
	'%': {0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03},

	//    (
	'(': {0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02},

	//    )
	')': {0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08},

	//    _
	'_': {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F},

	//    ° (degree symbol — tiny superscript circle)
	//    ##
	//   #  #
	//    ##
	'°': {0x06, 0x09, 0x09, 0x06, 0x00, 0x00, 0x00},

	//    ▸ (right-pointing triangle — 4 rows, widening)
	//    #
	//    ##
	//    ###
	//    ####
	//    ###
	//    ##
	//    #
	'▸': {0x10, 0x18, 0x1C, 0x1E, 0x1C, 0x18, 0x10},
}

// drawChar renders a single character onto the matrix at position (x, y).
// Returns the advance width in pixels (normally 6 = 5px glyph + 1px spacing).
// Characters not found in the font are skipped (treated as space).
func drawChar(m Matrix, x, y int, ch rune, r, gr, b uint8) int {
	gl, ok := font5x7[ch]
	if !ok {
		return 6 // treat unknown as space
	}

	for row := 0; row < 7; row++ {
		rowBits := gl[row]
		for col := 0; col < 5; col++ {
			// bit4 = leftmost (col 0), bit0 = rightmost (col 4)
			if (rowBits>>(4-col))&1 == 1 {
				m.SetPixel(x+col, y+row, r, gr, b)
			}
		}
	}
	return 6
}

// drawString renders a string onto the matrix starting at (x, y).
// Returns the total pixel width consumed.
func drawString(m Matrix, x, y int, text string, r, gr, b uint8) int {
	cx := x
	for _, ch := range text {
		cx += drawChar(m, cx, y, ch, r, gr, b)
	}
	return cx - x
}

// stringWidth returns the pixel width of text without drawing anything.
func stringWidth(text string) int {
	total := 0
	for range text {
		total += 6
	}
	return total
}

// ── 4×5 Small Font ────────────────────────────────────────────────────────
// 4 pixels wide, 5 pixels tall. Each glyph is [5]byte (one byte per row).
// Bit layout: bit3=leftmost, bit0=rightmost. Advance = 5px.

type smallGlyph [5]byte

var font4x5 = map[rune]smallGlyph{
	' ': {0x0, 0x0, 0x0, 0x0, 0x0},

	// Digits
	'0': {0x6, 0x9, 0x9, 0x9, 0x6}, //  ##  / #  # / #  # / #  # /  ##
	'1': {0x2, 0x6, 0x2, 0x2, 0x7}, //   #  /  ## /   #  /   #  /  ###
	'2': {0x6, 0x9, 0x2, 0x4, 0xF}, //  ##  / #  # /   #  /  #   / ####
	'3': {0x6, 0x1, 0x6, 0x1, 0x6}, //  ##  /    # /  ##  /    # /  ##
	'4': {0x9, 0x9, 0xF, 0x1, 0x1}, // #  # / #  # / #### /    # /    #
	'5': {0xF, 0x8, 0xE, 0x1, 0xE}, // #### / #    / ###  /    # / ###
	'6': {0x6, 0x8, 0xE, 0x9, 0x6}, //  ##  / #    / ###  / #  # /  ##
	'7': {0xF, 0x1, 0x2, 0x4, 0x4}, // #### /    # /   #  /  #   /  #
	'8': {0x6, 0x9, 0x6, 0x9, 0x6}, //  ##  / #  # /  ##  / #  # /  ##
	'9': {0x6, 0x9, 0x7, 0x1, 0x6}, //  ##  / #  # /  ### /    # /  ##

	// Uppercase letters
	'A': {0x6, 0x9, 0xF, 0x9, 0x9}, //  ##  / #  # / #### / #  # / #  #
	'B': {0xE, 0x9, 0xE, 0x9, 0xE}, // ###  / #  # / ###  / #  # / ###
	'C': {0x7, 0x8, 0x8, 0x8, 0x7}, //  ### / #    / #    / #    /  ###
	'D': {0xE, 0x9, 0x9, 0x9, 0xE}, // ###  / #  # / #  # / #  # / ###
	'E': {0xF, 0x8, 0xE, 0x8, 0xF}, // #### / #    / ###  / #    / ####
	'F': {0xF, 0x8, 0xE, 0x8, 0x8}, // #### / #    / ###  / #    / #
	'G': {0x7, 0x8, 0xB, 0x9, 0x7}, //  ### / #    / # ## / #  # /  ###
	'H': {0x9, 0x9, 0xF, 0x9, 0x9}, // #  # / #  # / #### / #  # / #  #
	'I': {0xE, 0x4, 0x4, 0x4, 0xE}, // ###  /  #   /  #   /  #   / ###
	'J': {0x7, 0x1, 0x1, 0x9, 0x6}, //  ### /    # /    # / #  # /  ##
	'K': {0x9, 0xA, 0xC, 0xA, 0x9}, // #  # / # #  / ##   / # #  / #  #
	'L': {0x8, 0x8, 0x8, 0x8, 0xF}, // #    / #    / #    / #    / ####
	'M': {0x9, 0xF, 0xF, 0x9, 0x9}, // #  # / #### / #### / #  # / #  #
	'N': {0x9, 0xD, 0xF, 0xB, 0x9}, // #  # / ## # / #### / # ## / #  #
	'O': {0x6, 0x9, 0x9, 0x9, 0x6}, //  ##  / #  # / #  # / #  # /  ##
	'P': {0xE, 0x9, 0xE, 0x8, 0x8}, // ###  / #  # / ###  / #    / #
	'Q': {0x6, 0x9, 0x9, 0xA, 0x5}, //  ##  / #  # / #  # / # #  /  # #
	'R': {0xE, 0x9, 0xE, 0xA, 0x9}, // ###  / #  # / ###  / # #  / #  #
	'S': {0x7, 0x8, 0x6, 0x1, 0xE}, //  ### / #    /  ##  /    # / ###
	'T': {0xF, 0x4, 0x4, 0x4, 0x4}, // #### /  #   /  #   /  #   /  #
	'U': {0x9, 0x9, 0x9, 0x9, 0x6}, // #  # / #  # / #  # / #  # /  ##
	'V': {0x9, 0x9, 0x9, 0x6, 0x6}, // #  # / #  # / #  # /  ##  /  ##
	'W': {0x9, 0x9, 0xF, 0xF, 0x9}, // #  # / #  # / #### / #### / #  #
	'X': {0x9, 0x9, 0x6, 0x9, 0x9}, // #  # / #  # /  ##  / #  # / #  #
	'Y': {0x9, 0x9, 0x6, 0x4, 0x4}, // #  # / #  # /  ##  /  #   /  #
	'Z': {0xF, 0x1, 0x6, 0x8, 0xF}, // #### /    # /  ##  / #    / ####

	// Symbols
	'.': {0x0, 0x0, 0x0, 0x0, 0x4}, //      /      /      /      /  #
	',': {0x0, 0x0, 0x0, 0x4, 0x8}, //      /      /      /  #   / #
	':': {0x0, 0x4, 0x0, 0x4, 0x0}, //      /  #   /      /  #   /
	'-': {0x0, 0x0, 0xF, 0x0, 0x0}, //      /      / #### /      /
	'+': {0x0, 0x4, 0xE, 0x4, 0x0}, //      /  #   / ###  /  #   /
	'/': {0x1, 0x2, 0x4, 0x8, 0x8}, //    # /   #  /  #   / #    / #
	'°': {0x6, 0x9, 0x6, 0x0, 0x0}, //  ##  / #  # /  ##  /      /
}

// drawCharSmall renders a single character using the 4×5 font.
// Returns advance width (5px = 4px glyph + 1px spacing).
func drawCharSmall(m Matrix, x, y int, ch rune, r, gr, b uint8) int {
	gl, ok := font4x5[ch]
	if !ok {
		// Try uppercase version for lowercase input
		if ch >= 'a' && ch <= 'z' {
			gl, ok = font4x5[ch-32]
		}
		if !ok {
			return 5 // treat unknown as space
		}
	}
	for row := 0; row < 5; row++ {
		rowBits := gl[row]
		for col := 0; col < 4; col++ {
			if (rowBits>>(3-col))&1 == 1 {
				m.SetPixel(x+col, y+row, r, gr, b)
			}
		}
	}
	return 5
}

// drawStringSmall renders a string using the 4×5 font.
// Returns total pixel width consumed.
func drawStringSmall(m Matrix, x, y int, text string, r, gr, b uint8) int {
	cx := x
	for _, ch := range text {
		cx += drawCharSmall(m, cx, y, ch, r, gr, b)
	}
	return cx - x
}

// stringWidthSmall returns the pixel width of text in the 4×5 font.
func stringWidthSmall(text string) int {
	return len([]rune(text)) * 5
}

// ── Airplane Icon (16×16) ───────────────────────────────────────────────────

// planeIcon is a 16×16 side-view airplane silhouette.
// Each [3]uint8 is {r, g, b}. Zero value means transparent (no pixel drawn).
// The plane faces right (nose pointing right).
//
// Layout sketch (# = filled pixel):
//
//	col:   0123456789ABCDEF
//	row 0: ................
//	row 1: ................
//	row 2: ................
//	row 3: ................
//	row 4: .........#......    <- tail fin top
//	row 5: ........##......    <- tail fin
//	row 6: .#######.#.....#   <- tail+fuselage+nose highlight
//	row 7: ##############.#   <- main fuselage + wing upper
//	row 8: ##############.#   <- main fuselage + wing lower
//	row 9: .#######.#.....#   <- underside
//	row10: ........##......    <- lower strake
//	row11: .........#......    <- engine/pod
//	row12: ................
//	row13: ................
//	row14: ................
//	row15: ................
//
// Wings span roughly columns 4–11 on rows 6–9 (wider body).
// We build this as a literal pixel map for precision.

var planeIcon = buildPlaneIcon()

func buildPlaneIcon() [16][16][3]uint8 {
	const (
		_ = iota // transparent
	)
	type px = [3]uint8
	// cyan color
	c := px{0, 200, 220}
	// dark cyan for depth on fuselage body
	dc := px{0, 140, 160}
	// off-white highlight on nose tip
	hi := px{200, 240, 255}

	var icon [16][16][3]uint8

	// Helper to set a pixel
	set := func(row, col int, color px) {
		if row >= 0 && row < 16 && col >= 0 && col < 16 {
			icon[row][col] = color
		}
	}

	// ── Tail fin (vertical stabilizer) ──────────────────────────────────
	set(4, 2, c)
	set(5, 2, c)
	set(5, 3, c)

	// ── Fuselage (horizontal, rows 6-9, cols 1-13) ──────────────────────
	// Row 6 — top of fuselage
	for col := 1; col <= 13; col++ {
		set(6, col, c)
	}
	set(6, 14, hi) // nose highlight upper

	// Row 7 — upper fuselage interior
	set(7, 0, c)
	for col := 1; col <= 13; col++ {
		set(7, col, dc)
	}
	set(7, 14, hi) // nose
	set(7, 15, hi)

	// Row 8 — lower fuselage interior
	set(8, 0, c)
	for col := 1; col <= 13; col++ {
		set(8, col, dc)
	}
	set(8, 14, hi) // nose
	set(8, 15, hi)

	// Row 9 — bottom of fuselage
	for col := 1; col <= 13; col++ {
		set(9, col, c)
	}
	set(9, 14, hi) // nose highlight lower

	// ── Wings (rows 5-10, centered around col 7-8) ──────────────────────
	// Upper wing surface (rows 5-6, expanding outward)
	set(5, 6, c)
	set(5, 7, c)
	set(4, 7, c)
	set(3, 8, c)

	// Lower wing surface
	set(10, 6, c)
	set(10, 7, c)
	set(11, 7, c)
	set(12, 8, c)

	// Wing span — wide at rows 6-9
	for col := 4; col <= 11; col++ {
		set(5, col, c)
		set(10, col, c)
	}

	// Winglets / tips
	set(4, 11, c)
	set(4, 12, c)
	set(11, 11, c)
	set(11, 12, c)

	// ── Tail horizontal stabilizer ───────────────────────────────────────
	for col := 1; col <= 4; col++ {
		set(5, col, c)
		set(10, col, c)
	}

	return icon
}

// drawPlaneIcon draws the airplane icon at position (x, y) on the matrix.
func drawPlaneIcon(m Matrix, x, y int) {
	for row := 0; row < 16; row++ {
		for col := 0; col < 16; col++ {
			px := planeIcon[row][col]
			if px[0] != 0 || px[1] != 0 || px[2] != 0 {
				m.SetPixel(x+col, y+row, px[0], px[1], px[2])
			}
		}
	}
}
