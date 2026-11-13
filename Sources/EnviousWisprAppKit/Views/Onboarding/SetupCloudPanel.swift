import EnviousWisprCore
import SwiftUI

/// The Cloud tab's content and footer. The See all host owns the tab bar and flow routing.
struct SetupCloudPanel: View {
  let model: SetupCloudPanelModel
  let onChoose: (LLMProvider, String) -> Void
  let onLater: () -> Void
  let onBack: () -> Void

  @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
  @Environment(\.overlayReduceMotionOverride) private var override
  @FocusState private var keyFocused: Bool
  @State private var revealed = false
  @State private var showModels = false

  private var reduceMotion: Bool { override ?? systemReduceMotion }
  private var name: String {
    PolishRailCatalog.entry(for: model.provider)?.name
      ?? model.provider.displayName
  }

  var body: some View {
    VStack(spacing: DesignSpacing.md) {
      providers
      keyHeading
      keyField
      if model.phase == .picker { modelField }
      statusText
        .font(.firstRunCaption)
        .foregroundStyle(statusColor)
        .frame(maxWidth: .infinity, alignment: .leading)
      Spacer(minLength: 0)
      SetupFooter(title: actionTitle, isEnabled: !model.isChecking, action: accept) {
        SetupLinkButton(title: "Recommended options", quiet: true, action: onBack)
        SetupLinkButton(title: "Add my key later", action: onLater)
      }
    }
    .animation(reduceMotion ? nil : DesignMotion.firstRunRise, value: model.phase)
    .onAppear { model.hydrate() }
    .onDisappear { revealed = false }
    .onChange(of: model.provider) {
      revealed = false
      showModels = false
    }
  }

  private var providers: some View {
    HStack(spacing: DesignSpacing.md) {
      // Key-based providers only; Setup never offers Ollama (founder; it stays in Settings).
      ForEach(
        PolishRailCatalog.providers(in: .cloud).filter {
          SavedKeyPresence.cloudProviders.contains($0.provider)
        }, id: \.provider
      ) { entry in
        let selected = entry.provider == model.provider
        Button {
          model.provider = entry.provider
        } label: {
          HStack(spacing: DesignSpacing.xs) {
            Text(verbatim: entry.name)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
            if selected && model.phase == .picker {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.firstRunSuccessText)
                .accessibilityHidden(true)
            }
          }
          .font(.firstRunCaption.weight(.semibold))
          .foregroundStyle(selected ? Color.obAccent : Color.obTextPrimary)
          .frame(maxWidth: .infinity)
          .padding(.vertical, DesignSpacing.lg)
          .background(
            selected ? Color.firstRunAccentSoft : Color.obSurface,
            in: RoundedRectangle(cornerRadius: DesignRadius.xl)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Provider")
  }

  private var keyHeading: some View {
    HStack {
      Text("\(name) API key").font(.firstRunCaption.weight(.semibold))
      Spacer()
      if let url = Self.keyURL(model.provider) {
        Link(destination: url) {
          Label("Get a key", systemImage: "arrow.up.right")
            .font(.firstRunCaption)
            .foregroundStyle(Color.obAccent)
        }
      }
    }
  }

  private var keyField: some View {
    let key = Binding(get: { model.key }, set: { model.edit($0) })
    return HStack(spacing: DesignSpacing.sm) {
      Group {
        if revealed {
          TextField("Your \(name) API key", text: key)
        } else {
          SecureField("Your \(name) API key", text: key)
        }
      }
      .focused($keyFocused)
      .textFieldStyle(.plain)
      .font(.firstRunLabel)
      .accessibilityLabel("\(name) API key")
      .onSubmit(accept)
      Button {
        revealed.toggle()
      } label: {
        Image(systemName: revealed ? "eye.slash" : "eye")
          .foregroundStyle(Color.obTextSecondary)
          .frame(width: SetupMetrics.linksHeight, height: SetupMetrics.linksHeight)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(revealed ? Text("Hide the key") : Text("Show the key"))
    }
    .padding(.horizontal, DesignSpacing.xl)
    .frame(height: SetupMetrics.fieldHeight)
    .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: DesignRadius.xl))
    .overlay {
      RoundedRectangle(cornerRadius: DesignRadius.xl)
        .strokeBorder(keyFocused ? Color.obAccent : Color.stInputBorder, lineWidth: 1)
        .allowsHitTesting(false)
    }
  }

  private var modelField: some View {
    VStack(alignment: .leading, spacing: DesignSpacing.sm) {
      Text("Model").font(.firstRunCaption.weight(.semibold))
      Button {
        showModels.toggle()
      } label: {
        HStack {
          if let selected = model.chosen {
            Text(verbatim: selected.localizedDisplayName)
          } else {
            Text("Choose a model")
          }
          Spacer()
          Image(systemName: "chevron.down").accessibilityHidden(true)
        }
        .font(.firstRunLabel)
        .padding(.horizontal, DesignSpacing.xl)
        .frame(height: SetupMetrics.fieldHeight)
        .background(Color.stInputBg, in: RoundedRectangle(cornerRadius: DesignRadius.xl))
        .overlay {
          RoundedRectangle(cornerRadius: DesignRadius.xl)
            .strokeBorder(Color.stInputBorder, lineWidth: 1)
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text("Model for \(name)"))
      .accessibilityValue(
        model.chosen?.localizedDisplayName ?? String(localized: "Choose a model")
      )
      .accessibilityHint("Opens the model list")
      .popover(isPresented: $showModels, arrowEdge: .bottom) { choices }
    }
  }

  private var choices: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: DesignSpacing.xs) {
        ForEach(model.models, id: \.id) { entry in
          Button {
            model.select(entry.id)
            showModels = false
          } label: {
            HStack {
              Text(verbatim: entry.localizedDisplayName).font(.firstRunLabel)
              Spacer()
              if model.recommended(entry) {
                Text("Recommended")
                  .font(.firstRunEyebrow)
                  .foregroundStyle(Color.firstRunSuccessText)
              }
            }
            .padding(DesignSpacing.md)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(model.chosen?.id == entry.id ? .isSelected : [])
        }
      }
      .padding(DesignSpacing.md)
    }
    .frame(idealHeight: 240, maxHeight: 300)
    .frame(width: SetupMetrics.buttonMaxWidth)
  }

  private var actionTitle: LocalizedStringKey {
    switch model.phase {
    case .checking: "Checking your key…"
    case .loading: "Loading models…"
    case .picker:
      if let chosen = model.chosen {
        "Continue with \(chosen.localizedDisplayName)"
      } else {
        "Choose a model"
      }
    case .idle, .empty, .rejected, .retry, .noModels: "Check my key"
    }
  }

  private var statusText: Text {
    if let waiting = model.waitingForOtherProviderMessage { return Text(waiting) }
    return Text(status)
  }

  private var status: LocalizedStringKey {
    switch model.phase {
    case .idle: "Sends text and dictation context to \(name). Never audio."
    case .empty: "Paste your \(name) key in the box first."
    case .checking: "Checking with \(name)…"
    case .loading: "Loading models…"
    case .rejected: "That key did not work. Copy it again from \(name) and paste it."
    case .retry: "Could not check your key. Try again."
    case .noModels: "No available models found. Check your key again or add it later."
    case .picker:
      if model.chosen != nil {
        "Key works. Saved in your Keychain."
      } else {
        "Key works. Saved in your Keychain. Now choose a model."
      }
    }
  }

  private var statusColor: Color {
    if model.waitingForOtherProviderMessage != nil { return .obTextSecondary }
    return switch model.phase {
    case .empty, .rejected, .retry: .firstRunErrorText
    case .picker: .firstRunSuccessText
    case .idle, .checking, .loading, .noModels: .obTextSecondary
    }
  }

  private func accept() {
    guard !model.isChecking else { return }
    if let choice = model.chosen {
      onChoose(model.provider, choice.id)
    } else if model.phase == .picker {
      showModels = true
    } else {
      _ = model.check()
      if model.phase == .empty { keyFocused = true }
    }
  }

  private static func keyURL(_ provider: LLMProvider) -> URL? {
    switch provider {
    case .openAI: URL(string: "https://platform.openai.com/api-keys")
    case .gemini: URL(string: "https://aistudio.google.com/apikey")
    case .claude: URL(string: "https://platform.claude.com/settings/keys")
    default: nil
    }
  }
}
