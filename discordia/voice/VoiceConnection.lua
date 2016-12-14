local AudioStream = require('./AudioStream')
local Buffer = require('../utils/Buffer')
local constants = require('./constants')
local FFmpegPipe = require('./FFmpegPipe')

local PCM_LEN = constants.PCM_LEN
local PCM_SIZE = constants.PCM_SIZE
local FRAME_SIZE = constants.FRAME_SIZE
local FFMPEG = constants.FFMPEG

local clamp = math.clamp
local format = string.format

local VoiceConnection, property, method = class('VoiceConnection')
VoiceConnection.__description = "Represents a connection to a Discord voice server."

function VoiceConnection:__init(encoder, channel, socket, voice)
	self._voice = voice
	self._socket = socket
	self._channel = channel
	self._encoder = encoder
	self._encrypt = voice._sodium.encrypt
	self._client = voice._client
	self._seq = 0
	self._timestamp = 0
	local header = Buffer(12)
	local nonce = Buffer(24)
	header[0] = 0x80
	header[1] = 0x78
	self._header = header
	self._nonce = nonce
end

function VoiceConnection:_prepare(udp, ip, port, ssrc)
	self._udp, self._ip, self._port, self._ssrc = udp, ip, port, ssrc
end

function VoiceConnection:_send(data)

	if self._closed then return end

	local header = self._header
	local nonce = self._nonce

	header:writeUInt16BE(2, self._seq)
	header:writeUInt32BE(4, self._timestamp)
	header:writeUInt32BE(8, self._ssrc)

	header:copy(nonce)

	self._seq = self._seq < 0xFFFF and self._seq + 1 or 0
	self._timestamp = self._timestamp < 0xFFFFFFFF and self._timestamp + FRAME_SIZE or 0

	local encrypted = self._encrypt(data, tostring(nonce), self._key)

	local len = #encrypted
	local packet = Buffer(12 + len)
	header:copy(packet)
	packet:writeString(12, encrypted, len)

	return self._udp:send(tostring(packet), self._ip, self._port)

end

local function getBitrate(self)
	return self._encoder:get_bitrate()
end

local function setBitrate(self, bitrate)
	return self._encoder:set_bitrate(clamp(bitrate, 8000, 128000))
end

local function play(self, source, duration)
	if self._stream then self._stream:stop() end
	return AudioStream(source, self):play(duration)
end

local function playFile(self, filename, duration)

	if not FFMPEG then
		return self._client:warning(format('Cannot stream %q. FFmpeg not found.', filename))
	end

	local pipe = FFmpegPipe(filename, self._client)

	local function source()
		return pipe:read(PCM_SIZE)
	end

	play(self, source, duration)
	pipe:close()

end

local function playBytes(self, bytes, duration)
	local buffer = Buffer(bytes)
	local offset = 0
	local len = #buffer
	local function source()
		if len - offset < 4 then return end
		local pcm = {}
		for i = 0, PCM_LEN - 1, 2 do
			pcm[i] = buffer:readInt16LE(offset)
			pcm[i + 1] = buffer:readInt16LE(offset + 2)
			offset = offset + 4
			if len - offset < 4 then break end
		end
		return pcm
	end
	return play(self, source, duration)
end

local function playPCM(self, pcm, duration)
	local len = #pcm
	local offset = 1
	local function source()
		if offset > len then return end
		local slice = {}
		for i = 1, PCM_LEN do
			slice[i] = pcm[offset]
			offset = offset + 1
		end
		return slice
	end
	return play(self, source, duration)
end

local function playWaveform(self, generator, duration)
	local function source()
		local pcm = {}
		for i = 0, PCM_LEN - 1, 2 do
			local left, right = generator()
			if not left and not right then return end
			pcm[i] = left or 0
			pcm[i + 1] = right or 0
		end
		return pcm
	end
	return play(self, source, duration)
end

local function pauseStream(self)
	if not self._stream then return end
	return self._stream:pause()
end

local function resumeStream(self)
	if not self._stream then return end
	return self._stream:resume()
end

local function stopStream(self)
	if not self._stream then return end
	return self._stream:stop()
end

property('channel', '_channel', nil, 'GuildVoiceChannel', "The channel for which the connection exists.")

method('getBitrate', getBitrate, nil, "Returns the current bitrate for the connection in bits per second.")
method('setBitrate', setBitrate, nil, "Sets the current bitrate for the connection (8000 to 128000 bps range).")
method('playFile', playFile, 'filename[, duration]', "Streams an audio file via FFmpeg.")
method('playBytes', playBytes, 'string[, duration]', "Interprets a Lua string as a byte array and streams it.")
method('playPCM', playPCM, 'table[, duration]', "Interprets a Lua table as a PCM array and streams it.")
method('playWaveform', playWaveform, 'generator[, duration]', "Streams PCM data returned from a generator function.")
method('pauseStream', pauseStream, nil, "Pauses the current audio stream, if one exists and is playing.")
method('resumeStream', resumeStream, nil, "Resumes the current audio stream, if one exists and is paused.")
method('stopStream', stopStream, nil, "Stops the current audio stream, if one exists.")

return VoiceConnection