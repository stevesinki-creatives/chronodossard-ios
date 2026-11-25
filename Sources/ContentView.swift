import SwiftUI
import AVFoundation

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = UIScreen.main.bounds
        view.layer.addSublayer(preview)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = uiView.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = uiView.bounds
        }
    }
}

struct ContentView: View {
    @StateObject private var engine = BibVisionEngine()
    @State private var selectedTab = 0
    @State private var raceTitle = "Course amicale"
    @State private var bulkNames = "Camille Laurent\nLucas Moreau\nChloé Tremblay\nNoah Gagnon"
    @State private var pdfURL: URL?

    var body: some View {
        TabView(selection: $selectedTab) {
            // ONGLET 1 : CHRONO CAMÉRA HAUTE VITESSE
            ZStack {
                CameraPreviewView(session: engine.session)
                    .ignoresSafeArea()

                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.yellow)
                        .frame(width: 4, height: geo.size.height)
                        .position(x: geo.size.width * engine.finishLineX, y: geo.size.height / 2)
                        .gesture(
                            DragGesture().onChanged { value in
                                engine.finishLineX = min(max(value.location.x / geo.size.width, 0.1), 0.9)
                            }
                        )

                    ForEach(Array(engine.detectedBibs.enumerated()), id: \.offset) { _, item in
                        let rect = CGRect(
                            x: item.box.minX * geo.size.width,
                            y: item.box.minY * geo.size.height,
                            width: item.box.width * geo.size.width,
                            height: item.box.height * geo.size.height
                        )
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.green, lineWidth: 3)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .overlay(
                                Text("#\(item.bib)")
                                    .font(.headline.bold())
                                    .padding(4)
                                    .background(Color.green)
                                    .foregroundColor(.black)
                                    .position(x: rect.midX, y: max(rect.minY - 16, 20))
                            )
                    }
                }

                VStack {
                    HStack {
                        Text(engine.formatTime(engine.elapsedTime))
                            .font(.system(size: 36, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(Color.black.opacity(0.8))
                            .cornerRadius(12)

                        Spacer()

                        Button(engine.use2xLens ? "Optique 2x" : "Optique 1x") {
                            engine.use2xLens.toggle()
                            engine.configureCamera()
                        }
                        .font(.subheadline.bold())
                        .padding(10)
                        .background(Color.orange)
                        .foregroundColor(.black)
                        .cornerRadius(10)
                    }
                    .padding()

                    if let toast = engine.lastToast {
                        Text(toast)
                            .font(.headline.bold())
                            .padding()
                            .background(Color.green)
                            .foregroundColor(.black)
                            .cornerRadius(10)
                    }

                    Spacer()

                    Button(action: {
                        engine.isRunning ? engine.stopRace() : engine.startRace()
                    }) {
                        Text(engine.isRunning ? "ARRÊTER LE CHRONO" : "DÉMARRER LA COURSE")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(engine.isRunning ? Color.red : Color.green)
                            .foregroundColor(.black)
                            .cornerRadius(14)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
            }
            .tabItem { Label("Chrono", systemImage: "camera.viewfinder") }
            .tag(0)

            // ONGLET 2 : COURSE & DOSSARDS PDF
            NavigationView {
                Form {
                    Section("Paramètres de l'épreuve") {
                        TextField("Titre de la course", text: $raceTitle)
                        Picker("Format", selection: $engine.raceMode) {
                            ForEach(RaceMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        if engine.raceMode == .fixedLaps {
                            Stepper("Nombre de tours : \(engine.targetLaps)", value: $engine.targetLaps, in: 1...50)
                        }
                    }

                    Section("Liste des participants (1 nom par ligne)") {
                        TextEditor(text: $bulkNames)
                            .frame(height: 110)
                        Button("Mettre à jour les dossards") {
                            let lines = bulkNames.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                            var newRoster: [String: String] = [:]
                            for (index, name) in lines.enumerated() {
                                newRoster["\(index + 1)"] = name
                            }
                            engine.roster = newRoster
                        }
                    }

                    Section("Impression US Letter (8.5 x 11)") {
                        Button("Générer le PDF des dossards (\(engine.roster.count))") {
                            pdfURL = engine.generateBibsPDF(raceTitle: raceTitle)
                        }
                        if let url = pdfURL {
                            ShareLink(item: url) {
                                Label("Ouvrir / Imprimer le PDF", systemImage: "printer.fill")
                                    .font(.headline)
                            }
                        }
                    }
                }
                .navigationTitle("Épreuve & Dossards")
            }
            .tabItem { Label("Dossards", systemImage: "printer") }
            .tag(1)

            // ONGLET 3 : RÉSULTATS
            NavigationView {
                List {
                    ForEach(engine.results) { res in
                        HStack {
                            Text("#\(res.bibNumber)")
                                .font(.title2.bold())
                                .frame(width: 65, alignment: .leading)
                            VStack(alignment: .leading) {
                                Text(res.name).font(.headline)
                                Text("Tours : \(res.laps)").font(.subheadline).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(engine.formatTime(res.finishTime ?? res.splitTimes.last ?? 0))
                                .font(.system(.headline, design: .monospaced))
                        }
                    }
                    if !engine.results.isEmpty {
                        Button("Réinitialiser les résultats", role: .destructive) {
                            engine.resetRace()
                        }
                    }
                }
                .navigationTitle("Résultats (\(engine.results.count))")
            }
            .tabItem { Label("Résultats", systemImage: "list.number") }
            .tag(2)
        }
        .preferredColorScheme(.dark)
    }
}
