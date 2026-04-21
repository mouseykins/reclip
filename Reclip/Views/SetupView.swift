import SwiftUI
import AppKit

struct SetupView: View {
    @Bindable var deps: DependencyCheck

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if !deps.installedHomebrew {
                    homebrewMissingSection
                } else {
                    missingDepsSection
                }

                Divider()

                installedSection
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("Setup Required")
                    .font(.largeTitle).bold()
            }
            Text("Reclip needs a few command-line tools to download and process videos. They can all be installed in one step.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var homebrewMissingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Homebrew is not installed", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text("Reclip uses Homebrew to install and manage its dependencies. Install Homebrew first, then come back and click Re-check.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Paste this into Terminal:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.black.opacity(0.25)))
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(#"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy to clipboard")
                }
            }

            HStack {
                Button("Open brew.sh") {
                    NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
                }
                Spacer()
                Button("Re-check") {
                    deps.recheck()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.3)))
    }

    private var missingDepsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Missing dependencies", systemImage: "shippingbox")
                .font(.headline)

            ForEach(deps.missing) { dep in
                dependencyRow(dep, installed: false)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await deps.installMissingViaHomebrew() }
                } label: {
                    HStack {
                        if deps.isInstalling {
                            ProgressView().scaleEffect(0.6)
                        }
                        Text(deps.isInstalling ? "Installing…" : "Install All with Homebrew")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(deps.isInstalling || deps.brewPath == nil)

                Button("Re-check") {
                    deps.recheck()
                }
                .disabled(deps.isInstalling)
            }

            Text("Or run manually: `brew install \(deps.missing.map(\.brewPackage).joined(separator: " "))`")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(.blue.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.blue.opacity(0.2)))
    }

    private var installedSection: some View {
        let installed = deps.dependencies.filter(\.isInstalled)
        return Group {
            if !installed.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Already installed", systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                    ForEach(installed) { dep in
                        dependencyRow(dep, installed: true)
                    }
                }
            }
        }
    }

    private func dependencyRow(_ dep: Dependency, installed: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(installed ? .green : .secondary)
                .font(.body)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(dep.displayName)
                        .font(.body).bold()
                    if let path = dep.installedPath {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Text(dep.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
