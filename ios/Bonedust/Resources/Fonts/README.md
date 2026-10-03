# Display font

`Typography.display` currently returns **SF Pro, black weight, expanded width**.
That is a stand-in, not the intended face.

## Dropping in Rubik Dirt

Rubik Dirt is licensed **OFL-1.1**, so bundling it in a paid app is fine — the
licence only requires that the font itself stay OFL and not be sold on its own.

1. Download `RubikDirt-Regular.ttf` from Google Fonts.
2. Put it in this directory. XcodeGen picks it up with the rest of `Resources`.
3. Add to `ios/project.yml` under the `Bonedust` target's `info.properties`:

   ```yaml
   UIAppFonts:
     - RubikDirt-Regular.ttf
   ```

4. In `UI/DesignTokens.swift`, change `Typography.display` to:

   ```swift
   static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .largeTitle) -> Font {
       .custom("RubikDirt-Regular", size: size, relativeTo: style)
   }
   ```

   `Font.custom(_:size:relativeTo:)` keeps Dynamic Type working, which matters
   because §7 requires it everywhere outside the slab.

That is the only change needed. Display type is used for the wordmark and large
headings only, so nothing else has to move.
