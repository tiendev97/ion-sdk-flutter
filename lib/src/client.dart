import 'dart:async';
import 'dart:io';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:sdp_transform/sdp_transform.dart';

import 'logger.dart';
import 'signal/signal.dart';
import 'stream.dart';

abstract class Sender {
  MediaStream get stream;

  /// [kind in 'video' | 'audio']
  RTCRtpTransceiver get transceivers;
}

class RTCConfiguration {
  /// 'vp8' | 'vp9' | 'h264'
  String codec;
}

class Transport {
  Transport(this.signal);

  static Future<Transport> create(
      {int role, Signal signal, Map<String, dynamic> config}) async {
    var transport = Transport(signal);
    var pc = await createPeerConnection(config);

    transport.pc = pc;

    if (role == RolePub) {
      transport.api = await pc.createDataChannel(
          'ion-sfu', RTCDataChannelInit()..maxRetransmits = 30);
    }

    pc.onDataChannel = (channel) {
      transport.api = channel;
      transport.onapiopen?.call();
    };

    pc.onIceCandidate = (candidate) {
      if (candidate != null) {
        signal.trickle(Trickle(target: role, candidate: candidate));
      }
    };

    return transport;
  }

  Function() onapiopen;
  RTCDataChannel api;
  Signal signal;
  RTCPeerConnection pc;
  List<RTCIceCandidate> candidates = [];
}

class Client {
  Client(this.signal);
  static Future<Client> create(
      {String sid, Signal signal, Map<String, dynamic> config}) async {
    var client = Client(signal);
    client.transports = {
      RolePub: await Transport.create(
          role: RolePub, signal: signal, config: config ?? defaultConfig),
      RoleSub: await Transport.create(
          role: RoleSub, signal: signal, config: config ?? defaultConfig)
    };

    client.transports[RoleSub].pc.onTrack = (RTCTrackEvent ev) {
      var remote = makeRemote(ev.streams[0], client.transports[RoleSub]);
      client.ontrack?.call(ev.track, remote);
    };

    client.transports[RoleSub].pc.onRemoveStream = (MediaStream mediaStream) {
      client.onRemoveStream?.call(mediaStream);
    };

    client.transports[RoleSub].pc.onRemoveTrack =
        (MediaStream mediaStream, MediaStreamTrack track) {
      client.onRemoveTrack?.call(mediaStream,track);
    };

    client.signal.onnegotiate = (desc) => client.negotiate(desc);
    client.signal.ontrickle = (trickle) => client.trickle(trickle);
    client.signal.onready = () async {
      if (!client.initialized) {
        // client.join(sid);
        client.initialized = true;
      }
    };
    client.signal.connect();
    return client;
  }

  static final defaultConfig = {
    'iceServers': [
      {
        // 'urls': 'stun:stun.stunprotocol.org:3478',
        'urls': [
          'stun:stun.l.google.com:19302',
          'stun:stun1.l.google.com:19302',
          'stun:stun2.l.google.com:19302',
          'stun:stun3.l.google.com:19302',
          'stun:stun4.l.google.com:19302',
        ]
      }
    ],
    'sdpSemantics': 'unified-plan',
    'codec': 'vp8',
  };

  bool initialized = false;
  Signal signal;
  Map<int, Transport> transports = {};
  Function(MediaStreamTrack track, RemoteStream stream) ontrack;
  Function(MediaStream stream) onRemoveStream;
  Function(MediaStream stream, MediaStreamTrack track) onRemoveTrack;

  Future<List<StatsReport>> getPubStats(MediaStreamTrack selector) {
    return transports[RolePub].pc.getStats(selector);
  }

  Future<List<StatsReport>> getSubStats(MediaStreamTrack selector) {
    return transports[RoleSub].pc.getStats(selector);
  }

  Future<void> publish(LocalStream stream) async {
    await stream.publish(transports[RolePub].pc);
    // await onnegotiationneeded();
  }

  void close() {
    transports.forEach((key, element) {
      element.pc.close();
      element.pc.dispose();
    });
    signal.close();
  }

  Future<void> join(String sid) async {
    try {
      var pc = transports[RolePub].pc;
      var offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      var answer = await signal.join(sid, offer);
      await pc.setRemoteDescription(answer);
      transports[RolePub].candidates.forEach((c) => pc.addCandidate(c));
      pc.onRenegotiationNeeded = () => onnegotiationneeded();
    } catch (e) {
      print('join: e => $e');
    }
  }

  void trickle(Trickle trickle) async {
    var pc = transports[trickle.target].pc;
    if (pc != null) {
      await pc.addCandidate(trickle.candidate);
    } else {
      transports[trickle.target].candidates.add(trickle.candidate);
    }
  }

  void negotiate(RTCSessionDescription description) async {
    try {
      var pc = transports[RoleSub].pc;
      await pc.setRemoteDescription(description);
      var answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      signal.answer(answer);
    } catch (err) {
      print('negotiate err = $err');
    }
  }

  Future<void> onnegotiationneeded() async {
    try {
      var pc = transports[RolePub].pc;
      var offer = await pc.createOffer();
      
            if(Platform.isIOS){
        final map = parse(offer.sdp);

        var payloads = parsePayloads(map['media'][2]['payloads']);

        String newPayLoads = '';

        payloads.forEach((e) {
          if(e != '100'){
            newPayLoads = newPayLoads + ' $e';
          }
        });

        newPayLoads = '100' + newPayLoads;

        map['media'][2]['payloads'] = newPayLoads;

        var sdp = write(map, null);

        offer.sdp = sdp;
      }

      
      await pc.setLocalDescription(offer);
      var answer = await signal.offer(offer);
      await pc.setRemoteDescription(answer);
    } catch (err) {
      log.error(err);
    }
  }
}

