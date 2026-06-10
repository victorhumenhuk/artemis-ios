import Core
import AVFAudio
import Foundation
@preconcurrency import LiveKitWebRTC
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Observable public final class WebRTCConnector: NSObject, Connector, Sendable {
	public enum WebRTCError: Error {
		case invalidEphemeralKey
		case missingAudioPermission
		case failedToCreateDataChannel
		case failedToCreatePeerConnection
		case badServerResponse(URLResponse)
		case failedToCreateSDPOffer(Swift.Error)
		case failedToSetLocalDescription(Swift.Error)
		case failedToSetRemoteDescription(Swift.Error)
	}

	public let events: AsyncThrowingStream<ServerEvent, Error>
	@MainActor public private(set) var status = RealtimeAPI.Status.disconnected

	public var isMuted: Bool {
		!audioTrack.isEnabled
	}

	package let audioTrack: LKRTCAudioTrack
	private let dataChannel: LKRTCDataChannel
	private let connection: LKRTCPeerConnection

	private let stream: AsyncThrowingStream<ServerEvent, Error>.Continuation

	// PATCH (Artemis): the audio processing module holds its delegates WEAKLY, so
	// the capture tap must be retained statically alongside the factory.
	static let captureTap = CaptureAudioTap()

	private static let factory: LKRTCPeerConnectionFactory = {
		LKRTCInitializeSSL()

		// PATCH (Artemis): inject an audio processing module whose capture
		// post-processing delegate hands us the echo-cancelled mic audio, so the
		// app can run a live on-device caption WITHOUT opening a second audio
		// client on the microphone (renderers on a local track are never fed).
		let apm = LKRTCDefaultAudioProcessingModule(
			config: nil,
			capturePostProcessingDelegate: captureTap,
			renderPreProcessingDelegate: nil)
		return LKRTCPeerConnectionFactory(
			audioDeviceModuleType: .platformDefault,
			bypassVoiceProcessing: false,
			encoderFactory: nil,
			decoderFactory: nil,
			audioProcessingModule: apm)
	}()

	private let encoder: JSONEncoder = {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		return encoder
	}()

	private let decoder: JSONDecoder = {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		return decoder
	}()

	// PATCH (Artemis): tap the mic audio WebRTC captures (echo-cancelled, via the
	// APM capture post-processing hook) so an on-device recogniser can show her
	// words live, on the exact audio the model hears.
	public nonisolated(unsafe) var onLocalAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?

	private init(connection: LKRTCPeerConnection, audioTrack: LKRTCAudioTrack, dataChannel: LKRTCDataChannel) {
		self.connection = connection
		self.audioTrack = audioTrack
		self.dataChannel = dataChannel
		(events, stream) = AsyncThrowingStream.makeStream(of: ServerEvent.self)

		super.init()

		connection.delegate = self
		dataChannel.delegate = self

		Self.captureTap.onBuffer = { [weak self] buf in self?.onLocalAudioBuffer?(buf) }
	}

	deinit {
		disconnect()
	}

	package func connect(using request: URLRequest) async throws {
		guard connection.connectionState == .new else { return }

		// PATCH (Artemis): do not hard-require the microphone. Typed text over the
		// data channel must work even when audio capture is unavailable (e.g. the
		// iOS Simulator). With permission we also configure capture/playback.
		let micGranted = AVAudioApplication.shared.recordPermission == .granted
		try await performHandshake(using: request)
		if micGranted { Self.configureAudioSession() }
	}

	public func send(event: ClientEvent) throws {
		let data = try encoder.encode(event)
		RealtimeRawTap.outbound?(String(data: data, encoding: .utf8) ?? "")   // PATCH (Artemis): outbound tap
		_ = dataChannel.sendData(LKRTCDataBuffer(data: data, isBinary: false))
	}

	public func disconnect() {
		connection.close()
		stream.finish()
	}

	public func toggleMute() {
		audioTrack.isEnabled.toggle()
	}
}

extension WebRTCConnector {
	public static func create(connectingTo request: URLRequest) async throws -> WebRTCConnector {
		let connector = try create()
		try await connector.connect(using: request)
		return connector
	}

	package static func create() throws -> WebRTCConnector {
		guard let connection = factory.peerConnection(
			with: LKRTCConfiguration(),
			constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
			delegate: nil
		) else { throw WebRTCError.failedToCreatePeerConnection }

		let audioTrack = Self.setupLocalAudio(for: connection)

		guard let dataChannel = connection.dataChannel(forLabel: "oai-events", configuration: LKRTCDataChannelConfiguration()) else {
			throw WebRTCError.failedToCreateDataChannel
		}

		return self.init(connection: connection, audioTrack: audioTrack, dataChannel: dataChannel)
	}
}

private extension WebRTCConnector {
	static func setupLocalAudio(for connection: LKRTCPeerConnection) -> LKRTCAudioTrack {
		let audioSource = factory.audioSource(with: LKRTCMediaConstraints(
			mandatoryConstraints: [
				"googNoiseSuppression": "true", "googHighpassFilter": "true",
				"googEchoCancellation": "true", "googAutoGainControl": "true",
			],
			optionalConstraints: nil
		))

		return tap(factory.audioTrack(with: audioSource, trackId: "local_audio")) { audioTrack in
			connection.add(audioTrack, streamIds: ["local_stream"])
		}
	}

	static func configureAudioSession() {
		#if !os(macOS)
		do {
			let audioSession = AVAudioSession.sharedInstance()
			#if os(tvOS)
			try audioSession.setCategory(.playAndRecord, options: [])
			#else
			try audioSession.setCategory(.playAndRecord, options: [.defaultToSpeaker])
			#endif
			try audioSession.setMode(.voiceChat)
			try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
			// PATCH (Artemis): force the loudspeaker. In playAndRecord the route
			// defaults to the quiet earpiece; override it so the voice is loud.
			try audioSession.overrideOutputAudioPort(.speaker)
		} catch {
			print("Failed to configure AVAudioSession: \(error)")
		}
		#endif
	}

	func performHandshake(using request: URLRequest) async throws {
		let sdp = try await Result { try await connection.offer(for: LKRTCMediaConstraints(mandatoryConstraints: ["levelControl": "true"], optionalConstraints: nil)) }
			.mapError(WebRTCError.failedToCreateSDPOffer)
			.get()

		do { try await connection.setLocalDescription(sdp) }
		catch { throw WebRTCError.failedToSetLocalDescription(error) }

		// PATCH (Artemis): guard the local SDP rather than force-unwrap (a nil here on a
		// flaky connection would crash the app instead of failing recoverably).
		guard let localSdp = connection.localDescription?.sdp else { throw WebRTCError.failedToSetLocalDescription(NSError(domain: "WebRTC", code: -1)) }
		let remoteSdp = try await fetchRemoteSDP(using: request, localSdp: localSdp)

		do { try await connection.setRemoteDescription(LKRTCSessionDescription(type: .answer, sdp: remoteSdp)) }
		catch { throw WebRTCError.failedToSetRemoteDescription(error) }
	}

	private func fetchRemoteSDP(using request: URLRequest, localSdp: String) async throws -> String {
		var request = request
		request.httpBody = localSdp.data(using: .utf8)
		request.setValue("application/sdp", forHTTPHeaderField: "Content-Type")

		let (data, response) = try await URLSession.shared.data(for: request)

		guard let response = response as? HTTPURLResponse, response.statusCode == 201, let remoteSdp = String(data: data, encoding: .utf8) else {
			if (response as? HTTPURLResponse)?.statusCode == 401 { throw WebRTCError.invalidEphemeralKey }
			throw WebRTCError.badServerResponse(response)
		}

		return remoteSdp
	}
}

extension WebRTCConnector: LKRTCPeerConnectionDelegate {
	public func peerConnectionShouldNegotiate(_: LKRTCPeerConnection) {}
	public func peerConnection(_: LKRTCPeerConnection, didAdd _: LKRTCMediaStream) {}
	public func peerConnection(_: LKRTCPeerConnection, didOpen _: LKRTCDataChannel) {}
	public func peerConnection(_: LKRTCPeerConnection, didRemove _: LKRTCMediaStream) {}
	public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCSignalingState) {}
	public func peerConnection(_: LKRTCPeerConnection, didGenerate _: LKRTCIceCandidate) {}
	public func peerConnection(_: LKRTCPeerConnection, didRemove _: [LKRTCIceCandidate]) {}
	public func peerConnection(_: LKRTCPeerConnection, didChange _: LKRTCIceGatheringState) {}

	public func peerConnection(_: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
		print("ICE Connection State changed to: \(newState)")
		if newState == .connected || newState == .completed {
			// PATCH (Artemis): re-route to the loudspeaker once connected.
			try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
		}
	}
}

/// PATCH (Artemis): taps the raw realtime JSON at the receive/send boundary for
/// the developer console. Raw inbound is emitted BEFORE decode; decode failures
/// are surfaced, never swallowed.
public enum RealtimeRawTap {
	public nonisolated(unsafe) static var inbound: (@Sendable (String) -> Void)?
	public nonisolated(unsafe) static var outbound: (@Sendable (String) -> Void)?
	public nonisolated(unsafe) static var decodeFailure: (@Sendable (String, Error) -> Void)?
}

/// PATCH (Artemis): the capture-path audio tap. Renderers attached to a LOCAL
/// track are never fed by WebRTC, so we hook the audio processing module's
/// capture POST-processing delegate instead: the echo-cancelled mic audio,
/// exactly what is sent to the model, delivered on the audio thread. The
/// LKRTCAudioBuffer is only valid inside the callback, so each one is copied
/// into an AVAudioPCMBuffer before forwarding for live transcription.
final class CaptureAudioTap: NSObject, LKRTCAudioCustomProcessingDelegate, @unchecked Sendable {
	nonisolated(unsafe) var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
	nonisolated(unsafe) private var format: AVAudioFormat?

	nonisolated(unsafe) private var loggedFirst = false

	func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
		format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRateHz), channels: 1, interleaved: false)
	}

	func audioProcessingProcess(audioBuffer: LKRTCAudioBuffer) {
		if !loggedFirst { loggedFirst = true; NSLog("CAPTAP: first mic buffer (frames=%d ch=%d) — live caption feed is live", audioBuffer.frames, audioBuffer.channels) }
		guard let onBuffer, let format, audioBuffer.channels > 0, audioBuffer.frames > 0 else { return }
		let frames = AVAudioFrameCount(audioBuffer.frames)
		guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
		      let dst = pcm.floatChannelData?[0] else { return }
		memcpy(dst, audioBuffer.rawBuffer(forChannel: 0), Int(frames) * MemoryLayout<Float>.size)
		pcm.frameLength = frames
		onBuffer(pcm)
	}

	func audioProcessingRelease() {
		format = nil
	}
}

extension WebRTCConnector: LKRTCDataChannelDelegate {
	public func dataChannel(_: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
		let raw = String(data: buffer.data, encoding: .utf8) ?? "<invalid utf8>"
		RealtimeRawTap.inbound?(raw)   // PATCH (Artemis): raw inbound JSON BEFORE decode
		do { try stream.yield(decoder.decode(ServerEvent.self, from: buffer.data)) }
		catch {
			// PATCH (Artemis): valid GA events the typed enum does not model are
			// ignored quietly (not a failure). Audio over WebRTC arrives on the
			// media track, so the audio buffer/delta events carry nothing we need.
			if Self.quietlyIgnored(Self.eventType(raw)) { return }
			// Other decode failures: surface, but DO NOT finish the stream.
			RealtimeRawTap.decodeFailure?(raw, error)
			print("Failed to decode server event (continuing): \(raw)")
		}
	}

	private static func eventType(_ raw: String) -> String {
		guard let r = raw.range(of: "\"type\"") else { return "" }
		let tail = raw[r.upperBound...]
		guard let colon = tail.firstIndex(of: ":") else { return "" }
		let after = tail[tail.index(after: colon)...].drop(while: { $0 == " " || $0 == "\"" })
		return String(after.prefix(while: { $0 != "\"" }))
	}

	private static func quietlyIgnored(_ type: String) -> Bool {
		// output_audio_buffer.{started,stopped,cleared} and the
		// response.output_audio.{delta,done} family. Note the trailing dot keeps
		// response.output_audio_transcript.* (which the enum DOES decode) handled.
		type.hasPrefix("output_audio_buffer.") || type.hasPrefix("response.output_audio.")
	}

	public func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {
		Task { @MainActor [state = dataChannel.readyState] in
			switch state {
				case .open: status = .connected
				case .closing, .closed: status = .disconnected
				default: break
			}
		}
	}
}
