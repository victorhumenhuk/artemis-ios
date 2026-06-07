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

	private static let factory: LKRTCPeerConnectionFactory = {
		LKRTCInitializeSSL()

		return LKRTCPeerConnectionFactory()
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

	// PATCH (Artemis): tap the LOCAL mic audio WebRTC captures so an on-device
	// recogniser can show her words live (the exact audio the model hears).
	public nonisolated(unsafe) var onLocalAudioBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
	private let localAudioTap = LocalAudioTap()

	private init(connection: LKRTCPeerConnection, audioTrack: LKRTCAudioTrack, dataChannel: LKRTCDataChannel) {
		self.connection = connection
		self.audioTrack = audioTrack
		self.dataChannel = dataChannel
		(events, stream) = AsyncThrowingStream.makeStream(of: ServerEvent.self)

		super.init()

		connection.delegate = self
		dataChannel.delegate = self

		localAudioTap.onBuffer = { [weak self] buf in self?.onLocalAudioBuffer?(buf) }
		audioTrack.add(localAudioTap)
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

		let remoteSdp = try await fetchRemoteSDP(using: request, localSdp: connection.localDescription!.sdp)

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

/// PATCH (Artemis): an audio renderer attached to the LOCAL mic track. WebRTC
/// delivers the captured PCM buffers here, which we forward so the app can run
/// live on-device transcription on the same audio the model hears.
final class LocalAudioTap: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
	nonisolated(unsafe) var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
	func render(pcmBuffer: AVAudioPCMBuffer) { onBuffer?(pcmBuffer) }
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
