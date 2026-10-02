import SwiftUI

/// First-run onboarding (#103, revised for the ring and the strap in #255). A short, dismissible,
/// re-openable flow that orients a new (non-developer) user before they land on the dashboard:
///   1. what OpenCircuit does — a RingConn ring or the Amazfit Helio Strap, local-first, written to
///      Apple Health, nothing leaves the device;
///   2. your wearable — pick the ring or the strap (the device in use is preselected and marked);
///      picking switches nothing, the device is changed in Profile ▸ Device;
///   3. getting started — the picked device's first steps (both, when nothing is picked): the ring
///      needs no official app or account (#106); the strap needs its key, plus decision 6's warnings;
///   4. permission priming — why Bluetooth + Apple Health are requested (the system prompts come
///      later, when the user first connects / authorizes Health — onboarding only explains them);
///   5. the not-affiliated / not-a-medical-device disclaimer, shared with Profile ▸ About. With the
///      strap picked and not set up, it ends by pushing the strap's setup screen.
///
/// Honest copy, no medical claims (the `trust` convention). Shown once on first launch via the
/// `OnboardingView.completedKey` flag (see ContentView), and re-openable from the profile screen's
/// About section. Pure presentation — it triggers no permission prompts and creates no central
/// itself; the decisions live in `OnboardingFlow`.
struct OnboardingView: View {
    /// Persisted flag: set once the user finishes/skips so the flow doesn't show again on launch.
    /// Versioned so a revised onboarding re-shows by bumping the suffix: v2 (#255) shows the device
    /// choice once to everyone who finished v1. The v1 key is left in place, never cleared.
    static let completedKey = "onboarding.completed.v2"

    /// Called when the user taps Get Started, Skip, or Done on the strap's setup — the caller
    /// persists the flag / dismisses.
    var onDone: () -> Void

    @State private var flow: OnboardingFlow
    @State private var page: OnboardingFlow.Page
    /// Onboarding-local: picking a card switches nothing (decision 51b).
    @State private var pick: ActiveDeviceChoice?
    @State private var showStrapSetup = false

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        let flow = OnboardingFlow(installed: .live())
        var page = OnboardingFlow.Page.welcome
        var pick = flow.preselection
#if DEBUG && targetEnvironment(simulator)
        if let id = UserDefaults.standard.string(forKey: OnboardingFlow.debugPageArgumentKey),
           let start = flow.debugStart(id) {
            page = start.page
            pick = start.pick
        }
#endif
        _flow = State(initialValue: flow)
        _page = State(initialValue: page)
        _pick = State(initialValue: pick)
    }

    private var isLastPage: Bool { page == .finish }
    private var finish: OnboardingFlow.Finish { flow.finish(for: pick) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcome.tag(OnboardingFlow.Page.welcome)
                    chooseWearable.tag(OnboardingFlow.Page.choose)
                    gettingStarted.tag(OnboardingFlow.Page.gettingStarted)
                    permissions.tag(OnboardingFlow.Page.permissions)
                    disclaimer.tag(OnboardingFlow.Page.finish)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                VStack(spacing: 4) {
                    Button(isLastPage ? finish.title : "Continue") {
                        if let next = OnboardingFlow.Page(rawValue: page.rawValue + 1) {
                            withAnimation { page = next }
                        } else if finish == .setUpStrap {
                            showStrapSetup = true
                        } else {
                            onDone()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    // Skip is redundant on the final page (its button finishes there).
                    Button("Skip", action: onDone)
                        .font(.footnote)
                        .opacity(isLastPage ? 0 : 1)
                        .disabled(isLastPage)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .toolbar(.hidden, for: .navigationBar)
            // The strap's existing setup screen, unchanged: its "Save key and use the Helio Strap"
            // is what switches. Done finishes onboarding from outside it.
            .navigationDestination(isPresented: $showStrapSetup) {
                HelioSetupView()
                    .toolbar(.visible, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", action: onDone)
                        }
                    }
            }
            .onChange(of: showStrapSetup) { _, showing in
                // Back from setup: a saved key or a switch changes what's in use.
                if !showing { flow = OnboardingFlow(installed: .live()) }
            }
        }
    }

    // MARK: Pages

    private var welcome: some View {
        page(title: "Welcome to OpenCircuit") {
            headerIcon(Image(systemName: "waveform.path.ecg"), tint: .blue)
        } content: {
            ForEach(OnboardingCopy.welcome, id: \.self) { bullet($0) }
        }
    }

    private var chooseWearable: some View {
        page(title: "Your wearable") {
            headerIcon(Image(keyline: .bluetooth), tint: Theme.accent)
        } content: {
            Text("Which one do you wear? Pick one to see its first steps.")
                .font(.body)
            ForEach(ActiveDeviceChoice.allCases, id: \.self) { card($0) }
            Text(OnboardingCopy.oneAtATime)
                .font(.subheadline).foregroundStyle(.secondary)
            Text(OnboardingCopy.changeLater)
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var gettingStarted: some View {
        page(title: "Getting started") {
            headerIcon(Image(systemName: "1.circle"), tint: .indigo)
        } content: {
            if let note = flow.switchNote(for: pick) {
                Text(note).font(.subheadline.weight(.semibold))
            }
            switch pick {
            case .ringConn:
                ringSteps
            case .helioStrap:
                strapSteps
            case nil:
                deviceHeading(.ringConn)
                ringSteps
                deviceHeading(.helioStrap)
                    .padding(.top, 8)
                strapSteps
            }
        }
    }

    private var permissions: some View {
        page(title: "Permissions") {
            headerIcon(Image(systemName: "lock.shield"), tint: .teal)
        } content: {
            bullet(OnboardingCopy.bluetoothPermission, icon: "dot.radiowaves.left.and.right")
            bullet("Apple Health — to save your metrics. You choose exactly what to share.",
                   icon: "heart.text.square")
            Text("You'll be asked for these the first time you connect and authorize Health.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.top, 4)
        }
    }

    private var disclaimer: some View {
        page(title: "Good to know") {
            headerIcon(Image(systemName: "info.circle"), tint: .orange)
        } content: {
            // The same constant as the About-section disclaimer in UserProfileSettingsView.
            Text(OnboardingCopy.disclaimer)
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: Device steps

    @ViewBuilder
    private var ringSteps: some View {
        ForEach(OnboardingCopy.ringSteps, id: \.self) { bullet($0) }
    }

    @ViewBuilder
    private var strapSteps: some View {
        bullet(OnboardingCopy.strapKey)
        Link("How to get the key", destination: OnboardingCopy.keyGuideURL)
            .font(.body)
            .padding(.leading, 28)
        ForEach(OnboardingCopy.strapWarnings, id: \.self) { bullet($0) }
        if let hint = flow.strapSetupHint(for: pick) {
            Text(hint).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func deviceHeading(_ device: ActiveDeviceChoice) -> some View {
        Text(device.displayName)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Wearable cards

    private func card(_ device: ActiveDeviceChoice) -> some View {
        let selected = pick == device
        return Button {
            withAnimation { pick = device }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                KeylineGlyph(selected ? .circleCheck : .circle, size: 22, relativeTo: .body)
                    .foregroundStyle(selected ? Theme.accent : Color.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(device.displayName).font(.body.weight(.semibold))
                        Spacer(minLength: 8)
                        if flow.inUse == device {
                            Text("In use").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                    Text(OnboardingCopy.cardDetail(device))
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(selected ? Theme.accent : Color.clear, lineWidth: 2))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(flow.cardAccessibilityLabel(device))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Page scaffold

    /// One page: scrolls when the text outgrows the screen (the largest accessibility sizes), and
    /// stays vertically centred when it doesn't. The bottom padding keeps the last line clear of
    /// the page dots.
    private func page(title: String, @ViewBuilder header: () -> some View,
                      @ViewBuilder content: () -> some View) -> some View {
        let header = header()
        let content = content()
        return GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Spacer(minLength: 8)
                    header
                    Text(title).font(.title.bold())
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 12) { content }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 44)   // clear the page dots
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private func headerIcon(_ image: Image, tint: Color) -> some View {
        image
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: 52, height: 52)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityHidden(true)
    }

    private func bullet(_ text: String, icon: String = "checkmark.circle.fill") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.tint).font(.body)
            Text(text).font(.body)
        }
    }
}
