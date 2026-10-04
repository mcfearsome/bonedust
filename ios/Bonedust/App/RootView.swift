import BonedustCore
import SwiftUI

/// M1's shell: pick a site, dig a slab, see what it paid, go again.
///
/// This is not §7's title screen. The run loop, supply tent and results screen arrive
/// at M2; until then this exists so the brush can be felt in isolation, which §9 calls
/// the most important thing to get right before anything else is built.
struct RootView: View {

    @State private var settings = GameSettings()
    /// The one palette the whole app reads. A dig on a dim site flips it through
    /// `DigScene.configureRenderer()`, so this is also where it is put back.
    @State private var theme = Theme()
    @State private var route: Route = .menu
    @State private var seed: UInt64 = UInt64.random(in: 1...UInt64.max >> 2)
    @State private var siteID = "charmouth"
    @State private var lastResult: SlabResult?

    private enum Route: Equatable {
        case menu
        case digging
    }

    private struct SlabResult: Equatable {
        var fossilName: String
        var period: String
        var formation: String
        var breakdown: PayoutBreakdown
        var bagged: Bool
        var gems: Int
    }

    private var site: Site {
        ContentCatalog.shared.site(siteID) ?? ContentCatalog.shared.sites[0]
    }

    var body: some View {
        content
            .environment(settings)
            .environment(\.theme, theme)
            // The page is cream by day and lamp-lit at night, and the status bar and
            // system controls follow it. Forced dark, the clock is white on cream.
            .preferredColorScheme(theme.ink == .night ? .dark : .light)
            .tint(theme.ink.stamp)
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .menu:
            menu
        case .digging:
            DigView(
                engine: DigEngine(
                    seed: seed,
                    site: site,
                    extraModifiers: settings.gentleModeModifiers
                ),
                onBagged: handleBagged
            )
            // A fresh engine per slab, keyed so SwiftUI rebuilds rather than reusing
            // the previous dig's state.
            .id(seed)
        }
    }

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BONEDUST")
                        .font(Typography.display(40))
                        .foregroundStyle(theme.ink.ink)
                    Text("Milestone 1 · brush feel")
                        .font(Typography.label(.caption))
                        .tracking(1.2)
                        .foregroundStyle(theme.ink.stamp)
                }
                .padding(.top, 18)

                if let result = lastResult { resultCard(result) }

                VStack(alignment: .leading, spacing: 8) {
                    FieldLabel(text: "Site")
                    ForEach(ContentCatalog.shared.sites) { candidate in
                        siteRow(candidate)
                    }
                }

                Toggle("Gentle mode", isOn: $settings.gentleMode)
                    .font(Typography.ui(.subheadline))
                    .foregroundStyle(theme.ink.ink)

                Button {
                    seed = UInt64.random(in: 1...UInt64.max >> 2)
                    // The dig opens already in its site's light. The scene sets the same
                    // value once it is up, but until then the page would be drawn in
                    // whatever the menu was, and a night dig would flash day first.
                    theme.lightLevel = site.modifiers.lightLevel
                    route = .digging
                } label: {
                    Text("New slab")
                        .font(Typography.ui(.headline, weight: .bold))
                        .foregroundStyle(theme.ink.page)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(theme.ink.stamp)
                        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
                }
            }
            .padding(.horizontal, Measure.gutter)
            .padding(.bottom, 32)
        }
        .background(theme.ink.page.ignoresSafeArea())
    }

    private func siteRow(_ candidate: Site) -> some View {
        Button {
            siteID = candidate.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(candidate.name)
                        .font(Typography.ui(.subheadline, weight: .semibold))
                        .foregroundStyle(theme.ink.ink)
                    Spacer()
                    Text(candidate.period.uppercased())
                        .font(Typography.label(.caption2))
                        .tracking(1)
                        .foregroundStyle(theme.ink.muted)
                }
                Text(candidate.twist)
                    .font(Typography.ui(.caption))
                    .foregroundStyle(theme.ink.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.ink.raised)
            .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Measure.cardRadius)
                    .stroke(
                        candidate.id == siteID ? theme.ink.stamp : theme.ink.hairline,
                        lineWidth: candidate.id == siteID ? 1.5 : Measure.hairline
                    )
            )
        }
        .accessibilityAddTraits(candidate.id == siteID ? [.isSelected, .isButton] : .isButton)
    }

    /// A first pass at §7.4's museum-label specimen tag.
    private func resultCard(_ result: SlabResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            FieldLabel(text: result.bagged ? "Bagged" : "Out of daylight")
            Text(result.fossilName)
                .font(Typography.display(21))
                .foregroundStyle(theme.ink.ink)
            Text("\(result.period) · \(result.formation)")
                .font(Typography.ui(.caption))
                .foregroundStyle(theme.ink.muted)
            SpecimenRule()
            grid(result)
            SpecimenRule()
            HStack {
                Text("TOTAL")
                    .font(Typography.label(.caption2))
                    .tracking(1.2)
                    .foregroundStyle(theme.ink.muted)
                Spacer()
                Text("$\(result.breakdown.total)")
                    .font(Typography.number(.title3, weight: .bold))
                    .foregroundStyle(theme.ink.stamp)
                    .monospacedDigit()
            }
        }
        .padding(13)
        .background(theme.ink.raised)
        .clipShape(RoundedRectangle(cornerRadius: Measure.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Measure.cardRadius)
                .stroke(theme.ink.hairline, lineWidth: Measure.hairline)
        )
    }

    private func grid(_ result: SlabResult) -> some View {
        VStack(spacing: 3) {
            line("Exposed", "\(Int((result.breakdown.exposure * 100).rounded()))%")
            line("Intact", "\(Int((result.breakdown.intact * 100).rounded()))%")
            line("Fossil", "$\(result.breakdown.fossil)")
            if result.gems > 0 {
                line("Gems (\(result.gems))", "$\(result.breakdown.gems)")
            }
            if result.breakdown.bonuses > 0 {
                line("Bonuses", "$\(result.breakdown.bonuses)")
            }
            if result.breakdown.multiplier != 1 {
                line("Multiplier", String(format: "x%.2f", result.breakdown.multiplier))
            }
        }
    }

    private func line(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name)
                .font(Typography.ui(.caption))
                .foregroundStyle(theme.ink.muted)
            Spacer()
            Text(value)
                .font(Typography.number(.caption, weight: .medium))
                .foregroundStyle(theme.ink.ink)
                .monospacedDigit()
        }
    }

    private func handleBagged(_ engine: DigEngine) {
        var bagged = false
        if case .finished(let wasBagged) = engine.phase { bagged = wasBagged }
        lastResult = SlabResult(
            fossilName: engine.fossil.name,
            period: engine.fossil.period,
            formation: engine.fossil.formation,
            breakdown: engine.payout(),
            bagged: bagged,
            gems: engine.wholeGems
        )
        // The menu is not lit by any site. Left alone, a night dig would leave it in
        // the night palette until the next dig happened to set the light again.
        theme.lightLevel = 1
        route = .menu
    }
}
