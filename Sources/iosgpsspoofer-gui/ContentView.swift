import CoreLocation
import MapKit
import SwiftUI
import SpooferCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260, max: 340)
        } detail: {
            if let error = model.setupError {
                SetupErrorView(message: error)
            } else if model.selectedDevice == nil {
                ContentUnavailableView(
                    "No iPhone selected",
                    systemImage: "iphone.slash",
                    description: Text("Connect and trust an iPhone (iOS 17+), then pick it from the list.")
                )
            } else {
                ControlPanelView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .task { model.startAutoRefresh() }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedUDID) {
            Section("Connected iPhones") {
                if model.devices.isEmpty {
                    Text("No devices detected")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(model.devices) { device in
                    DeviceRow(device: device).tag(device.udid)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.isRefreshing)
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(.bar)
        }
        .navigationTitle("Devices")
    }
}

struct DeviceRow: View {
    let device: Device

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.connectionLabel == "usb" ? "cable.connector" : "wifi")
                .foregroundStyle(device.connectionLabel == "usb" ? Color.accentColor : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.deviceName).fontWeight(.medium).lineLimit(1)
                Text("iOS \(device.productVersion) · \(device.modelName)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if device.majorVersion != 0 && device.majorVersion < 17 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("iOS 17+ recommended for this method")
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Setup error

struct SetupErrorView: View {
    @Environment(AppModel.self) private var model
    let message: String

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.system(size: 42)).foregroundStyle(.secondary)
                Text("pymobiledevice3 not found").font(.title2).bold()
                Text(message)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 460)
                Text("Run `./setup.sh` in the project directory, then retry.")
                    .font(.callout.monospaced())
                Button("Retry") { model.resolveTool() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Control panel

struct ControlPanelView: View {
    @Environment(AppModel.self) private var model
    @State private var recenterToken = 0

    var body: some View {
        HSplitView {
            mapSection
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

            settingsPanel
                .frame(minWidth: 320, idealWidth: 370, maxWidth: 520)
        }
        .onAppear { model.scheduleGeocode() }
        .onChange(of: model.selectedUDID) { recenterToken += 1 }
        .onChange(of: model.editMode) { recenterToken += 1 }
        .onChange(of: model.latitudeText) { model.scheduleGeocode() }
        .onChange(of: model.longitudeText) { model.scheduleGeocode() }
    }

    // Right-hand settings column

    private var settingsPanel: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Mode", selection: $model.editMode) {
                        ForEach(AppModel.EditMode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(model.hasActiveSession)

                    if model.editMode == .point {
                        coordinateSection
                    } else {
                        routeSection
                    }
                    transportSection

                    Text(statusDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    logSection
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            actionBar
        }
        .background(.windowBackground)
    }

    // Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.gen3").font(.title).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.selectedDevice?.deviceName ?? "—").font(.headline).lineLimit(1)
                Text(model.selectedDevice?.summary ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            StatusBadge(state: model.sessionState)
        }
        .padding(12)
    }

    // Map

    private var mapSection: some View {
        MapPicker(
            pins: model.mapPins,
            route: model.mapRoute,
            recenterToken: recenterToken,
            onClick: { c in model.handleMapClick(lat: c.latitude, lon: c.longitude) },
            onDragPin: { id, c in model.handleMapPinDrag(id: id, lat: c.latitude, lon: c.longitude) }
        )
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.editMode == .point
                      ? "Click to set the location — the pin is draggable"
                      : "Click to add a waypoint — drag any pin to move it",
                      systemImage: "hand.tap")
                    .font(.caption)
                if model.editMode == .point, let place = model.placeName {
                    Text(place).font(.caption.bold()).lineLimit(2)
                }
            }
            .padding(7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .padding(8)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .bottomTrailing) {
            Button { recenterToken += 1 } label: { Image(systemName: "scope") }
                .help("Fit the map to the pin(s)")
                .padding(10)
        }
    }

    // Coordinates (fixed-point mode)

    private var coordinateSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Coordinates")
            HStack(alignment: .top, spacing: 10) {
                LabeledField(label: "Latitude", text: $model.latitudeText)
                LabeledField(label: "Longitude", text: $model.longitudeText)
            }
            HStack(spacing: 14) {
                Menu {
                    ForEach(NamedLocation.presets) { preset in
                        Button(preset.name) { model.applyPreset(preset) }
                    }
                } label: {
                    Label("Presets", systemImage: "mappin.and.ellipse")
                }
                .menuStyle(.borderlessButton).fixedSize()

                Button {
                    if let s = NSPasteboard.general.string(forType: .string) {
                        model.pasteCoordinate(s)
                    }
                } label: {
                    Label("Paste \"lat, lon\"", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .font(.callout)

            if model.enteredCoordinate == nil {
                Label("Enter two decimal numbers", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    // Route mode

    private var routeSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle("Waypoints (\(model.waypoints.count))")
                Spacer()
                if !model.waypoints.isEmpty {
                    Button("Clear all", role: .destructive) { model.clearWaypoints() }
                        .buttonStyle(.link).font(.caption)
                }
            }

            if model.waypoints.isEmpty {
                Text("Click the map to drop point A, then point B, then any points in between.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(model.waypoints.enumerated()), id: \.element.id) { index, wp in
                        WaypointRow(
                            index: index,
                            waypoint: wp,
                            isFirst: index == 0,
                            isLast: index == model.waypoints.count - 1,
                            onUp: { model.reorderWaypoints(from: [index], to: index - 1) },
                            onDown: { model.reorderWaypoints(from: [index], to: index + 2) },
                            onInsert: { model.insertMidpointAfter(id: wp.id) },
                            onDelete: { model.removeWaypoint(id: wp.id) }
                        )
                    }
                }
            }

            pacingControls

            if model.waypoints.count >= 2 {
                Label(model.routeSummary, systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var pacingControls: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Pace")
            Picker("Pace by", selection: $model.routePacing) {
                ForEach(AppModel.RoutePacing.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 180)

            if model.routePacing == .time {
                HStack(spacing: 4) {
                    unitField("hr", $model.routeHoursText)
                    Text(":").foregroundStyle(.secondary)
                    unitField("min", $model.routeMinutesText)
                    Text(":").foregroundStyle(.secondary)
                    unitField("sec", $model.routeSecondsText)
                }
                if let v = model.routeSpeedKmh, v > 0 {
                    Text(String(format: "≈ %.0f km/h", v))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    TextField("30", text: $model.routeSpeedText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .font(.body.monospacedDigit())
                    Text("km/h").foregroundStyle(.secondary)
                }
                if let d = model.routeDuration {
                    Text("≈ \(AppModel.durationLabel(d))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if model.waypoints.count >= 2 {
                    Text("enter a speed above 0").font(.caption).foregroundStyle(.orange)
                }
            }

            Toggle("Loop the route", isOn: $model.routeLoop)
                .toggleStyle(.checkbox)
        }
    }

    private func unitField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(spacing: 2) {
            TextField("0", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 46)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // Transport

    private var transportSection: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Tunnel transport")
            Picker("", selection: $model.transport) {
                ForEach(Transport.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup).labelsHidden()
            .disabled(model.hasActiveSession)
        }
    }

    // Log

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle("Log")
            LogConsole(lines: model.logLines)
                .frame(height: 130)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        }
    }

    // Pinned action bar

    private var actionBar: some View {
        VStack(spacing: 8) {
            if model.editMode == .point, model.isSpoofing, model.hasPendingCoordinateChange {
                Button {
                    model.applyCoordinate()
                } label: {
                    Label("Move to new coordinates", systemImage: "arrow.up.forward")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            if model.editMode == .route, model.hasActiveSession, model.hasPendingRouteChange {
                Button {
                    model.applyRoute()
                } label: {
                    Label("Apply route changes & restart", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }

            Button {
                model.toggleSpoof()
            } label: {
                Label(mainButtonTitle, systemImage: mainButtonIcon)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.hasActiveSession ? .red : .accentColor)
            .disabled(mainButtonDisabled)
            .keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .background(.bar)
    }

    private var mainButtonTitle: String {
        if model.hasActiveSession { return "Stop & restore real GPS" }
        return model.editMode == .point ? "Start spoofing" : "Start route"
    }
    private var mainButtonIcon: String {
        if model.hasActiveSession { return "stop.fill" }
        return model.editMode == .point ? "location.fill" : "play.fill"
    }
    private var mainButtonDisabled: Bool {
        if model.hasActiveSession { return false }
        if model.selectedDevice == nil { return true }
        switch model.editMode {
        case .point: return model.enteredCoordinate == nil
        case .route: return model.waypoints.count < 2 || model.routeDuration == nil
        }
    }

    private var statusDescription: String {
        switch model.sessionState {
        case .idle:
            return "The device reports its real GPS. Spoofing clears automatically when you stop or quit."
        case .preparing:
            return "Establishing the developer tunnel and mounting the DeveloperDiskImage…"
        case .active(let lat, let lon):
            return "Holding the device at \(lat), \(lon)."
        case .routing(let summary):
            return "Moving the device along the route — \(summary)."
        case .completed:
            return "Route finished. The device is sitting at the last waypoint until you stop."
        case .interrupted(let why):
            return "Interrupted: \(why). Will resume when the device reconnects."
        case .failed(let msg):
            return "Failed: \(msg)"
        }
    }
}

struct WaypointRow: View {
    let index: Int
    let waypoint: AppModel.Waypoint
    let isFirst: Bool
    let isLast: Bool
    var onUp: () -> Void
    var onDown: () -> Void
    var onInsert: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.caption.bold().monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Color.red.opacity(0.15), in: Circle())
            Text(String(format: "%.5f, %.5f", waypoint.latitude, waypoint.longitude))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(action: onUp) { Image(systemName: "chevron.up") }.disabled(isFirst)
            Button(action: onDown) { Image(systemName: "chevron.down") }.disabled(isLast)
            Button(action: onInsert) { Image(systemName: "plus.circle") }
                .help("Insert a point after this one")
            Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Small components

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.caption).bold().foregroundStyle(.secondary).kerning(0.5)
    }
}

struct LabeledField: View {
    let label: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.body.monospacedDigit())
        }
    }
}

struct StatusBadge: View {
    let state: SpoofState
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption).bold()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
        .fixedSize()
    }
    private var title: String {
        switch state {
        case .idle: return "Idle"
        case .preparing: return "Preparing"
        case .active: return "Spoofing"
        case .routing: return "Moving"
        case .completed: return "Arrived"
        case .interrupted: return "Waiting"
        case .failed: return "Error"
        }
    }
    private var color: Color {
        switch state {
        case .idle: return .secondary
        case .preparing: return .orange
        case .active: return .green
        case .routing: return .green
        case .completed: return .blue
        case .interrupted: return .yellow
        case .failed: return .red
        }
    }
}

struct LogConsole: View {
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}
