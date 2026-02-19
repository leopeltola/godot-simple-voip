# GodotSimpleVOIP

A lightweight VOIP plugin for Godot that handles voice transmission over multiplayer networks.

## Features

- **Automatic voice capture and compression** using Opus codec
- **Neural network-based noise reduction** using RNNoise
- **Easy-to-use API** with a global singleton
- **Flexible voice routing** to multiple AudioStreamPlayers
- **Built-in audio processing** including EQ, compression, and limiting

## API

### Global Singleton: `VOIP`

The plugin automatically registers a global `VOIP` singleton that handles all voice transmission.

#### Properties

- `sending_voice: bool` - Enable/disable sending voice to peers (default: true)
- `peer_filter: Array[int]` - List of peer IDs that won't receive your voice (for bandwidth optimization)

#### Signals

- `peer_voice_data_received(peer_id: int, pcm_data: PackedVector2Array)` - Emitted when voice data is received from a peer

#### Setup

The plugin automatically:
1. Creates an audio bus named "VOIP" (or uses an existing one)
2. Sets up audio processing effects (EQ, noise reduction, compression, limiting)
3. Captures microphone input
4. Encodes voice with Opus codec
5. Sends compressed data to all connected peers via RPC

### AudioStreamVOIP

A custom AudioStream for playing voice from specific peers.

#### Usage

```gdscript
# Create an AudioStreamPlayer with an AudioStreamVOIP
var player = AudioStreamPlayer.new()

var voip_stream = AudioStreamVOIP.new()
voip_stream.peer_id = peer_id  # Set which peer's voice to play
player.stream = voip_stream

add_child(player)
player.play()
```

#### Properties

- `peer_id: int` - The peer ID whose voice should be played (set to 0 to disable)

#### How It Works

1. When `peer_id` is set to a non-zero value, AudioStreamVOIP subscribes to the `VOIP.peer_voice_data_received` signal
2. When voice data arrives from that peer, it's automatically pushed to the audio playback buffer
3. The audio is played through the AudioStreamPlayer as usual
4. Multiple AudioStreamVOIP instances can listen to the same peer simultaneously

## Setup

1. Ensure you have a multiplayer peer set up: 
   ```gdscript
   var peer = ENetMultiplayerPeer.new()
   peer.create_server(port)  # or create_client()
   multiplayer.multiplayer_peer = peer
   ```

2. Enable the plugin in Project Settings → Plugins

3. Create AudioStreamPlayers with AudioStreamVOIP streams when peers connect:
   ```gdscript
   func _on_peer_connected(peer_id: int) -> void:
       var player = AudioStreamPlayer.new()
       var voip_stream = AudioStreamVOIP.new()
       voip_stream.peer_id = peer_id
       player.stream = voip_stream
       add_child(player)
       player.play()
   ```

## Custom Audio Bus

If you prefer to set up your own audio bus instead of using the automatic one:

1. Create an audio bus named "VOIP" in your project
2. Add an `AudioEffectCapture` effect to it for microphone input
3. (Optional) Add other effects for processing

The plugin will detect the existing "VOIP" bus and use it instead of creating a new one.

## Configuration

Adjust voice transmission with these properties on the VOIP singleton:

```gdscript
# Stop sending voice
VOIP.sending_voice = false

# Don't send voice to specific peers
VOIP.peer_filter = [peer_id_1, peer_id_2]

# Re-enable later
VOIP.sending_voice = true
VOIP.peer_filter = []
```

## Notes

- Voice is sent using unreliable ordered RPC for low latency
- Voice data is compressed using Opus at approximately 48kHz sample rate
- The microphone input is captured from the "VOIP" audio bus
- Audio processing happens server-side before compression
