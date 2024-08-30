package sine_wave_generator

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"
import ma "vendor:miniaudio"
import rl "vendor:raylib"

OUTPUT_NUM_CHANNELS :: 1
OUTPUT_SAMPLE_RATE :: 44100
PREFERRED_BUFFER_SIZE :: 512
OUTPUT_BUFFER_SIZE :: OUTPUT_SAMPLE_RATE * size_of(f32) * OUTPUT_NUM_CHANNELS

// square wave testing
duty_cycle_mode: int
harmonics: f32 = 18

App :: struct {
	time:        f64,
	device:      ma.device,
	buffer_size: int,
	ring_buffer: Buffer,
	mutex:       sync.Mutex,
	sema:        sync.Sema,
}

screen_width :: 1200
screen_height :: 1200

app: App

KeyEvent :: struct {
	key:     int,
	freq:    f32,
	pressed: bool, // true for pressed, false for unpressed (released)
}

data_channel: chan.Chan(KeyEvent)

main :: proc() {

	err: runtime.Allocator_Error
	data_channel, err = chan.create_buffered(chan.Chan(KeyEvent), 20, context.allocator)

	if err != .None {
		os.exit(1)
	}

	// chan.send(channel, KeyEvent{rand.int_max(20)})
	// chan.send(channel, KeyEvent{1, 200, true})
	// chan.send(channel, KeyEvent{0, 300, true})
	// chan.send(channel, KeyEvent{3, 400, true})

	rl.InitWindow(screen_width, screen_height, "Sine Wave Generator")
	rl.SetTargetFPS(60)

	fmt.println("Initializing audio buffer")
	result: ma.result

	// set audio device settings
	device_config := ma.device_config_init(ma.device_type.playback)
	device_config.playback.format = ma.format.f32
	device_config.playback.channels = OUTPUT_NUM_CHANNELS
	device_config.sampleRate = OUTPUT_SAMPLE_RATE
	device_config.dataCallback = ma.device_data_proc(audio_callback)
	device_config.periodSizeInFrames = PREFERRED_BUFFER_SIZE

	fmt.println("Configuring MiniAudio Device")
	if (ma.device_init(nil, &device_config, &app.device) != .SUCCESS) {
		fmt.println("Failed to open playback device.")
		return
	}

	// get audio device info just so we can get thre real device buffer size
	info: ma.device_info
	ma.device_get_info(&app.device, ma.device_type.playback, &info)
	app.buffer_size = int(app.device.playback.internalPeriodSizeInFrames)

	// initialize ring buffer to be 8 times the size of the audio device buffer...
	buffer_init(&app.ring_buffer, app.buffer_size * OUTPUT_NUM_CHANNELS * 8)

	// starts the audio device and the audio callback thread
	fmt.println("Starting MiniAudio Device:", runtime.cstring_to_string(cstring(&info.name[0])))
	if (ma.device_start(&app.device) != .SUCCESS) {
		fmt.println("Failed to start playback device.")
		ma.device_uninit(&app.device)
		return
	}

	// start separate thread for generating audio samples
	// pass in a pointer to "app" as the data
	thread.run_with_data(&app, sample_generator_thread_proc)

	// main loop
	for !rl.WindowShouldClose() {
		rl.BeginDrawing()
		defer rl.EndDrawing()
		rl.ClearBackground(rl.BLACK)

		// rl.DrawText("Press Key:", 200, 150, 60, rl.WHITE)

		for channel, i in channels {

			root_pos_x: i32 = 50
			root_pos_y: i32 = 50


			row_pos := i

			if i > 4 {
				root_pos_y = 700
				row_pos = i - 5
			} else {

			}

			rl.DrawText(
				rl.TextFormat("Channel: %i", i),
				root_pos_x + i32(row_pos) * 200,
				root_pos_y,
				25,
				rl.WHITE,
			)
			rl.DrawText(
				rl.TextFormat("Freq: %f", channel.freq),
				root_pos_x + i32(row_pos) * 200,
				root_pos_y + 50,
				25,
				rl.WHITE,
			)
			rl.DrawText(
				rl.TextFormat("is pressed: %i", channel.is_pressed ? 1 : 0),
				root_pos_x + i32(row_pos) * 200,
				root_pos_y + 100,
				25,
				rl.WHITE,
			)
			rl.DrawText(
				rl.TextFormat("last_amp: %f", channel.last_amp),
				root_pos_x + i32(row_pos) * 200,
				root_pos_y + 150,
				25,
				rl.WHITE,
			)
		}

		// Draw the current buffer state proportionate to the screen

		// notes := []f32{523.251, 587.330, 659.255, 698.456, 783.991, 880, 987.767, 1046.5}
		notes := []f32{45, 110, 220, 659.255, 698.456, 783.991, 880, 987.767}

		for i in 0 ..< screen_width {
			position: rl.Vector2
			position.x = f32(i)
			audio_val := sample_triangle_wave(notes[0], f64(i) * 2 / f64(screen_width * notes[0]))
			position.y = 500 + 100 * f32(audio_val)
			rl.DrawPixelV(position, rl.RED)
		}

		// KEYS
		//     | s | d |    | g | h | j |
		//   | z | x | c | v | b | n | m |

		keyboard_keys := []rl.KeyboardKey{.Z, .X, .C, .V, .B, .N, .M, .COMMA}

		for key, ki in keyboard_keys {
			// draw keyboard

			freq := notes[ki]

			// get note frequency from key presses
			if rl.IsKeyPressed(key) {
				chan.send(data_channel, KeyEvent{ki, freq, true})
			}

			if rl.IsKeyReleased(key) {
				chan.send(data_channel, KeyEvent{ki, freq, false})
			}
		}

		if rl.IsKeyPressed(.KP_8) {
			duty_cycle_mode = (duty_cycle_mode - 1)
			if duty_cycle_mode < 0 {
				duty_cycle_mode = 3
			}
		}
		if rl.IsKeyPressed(.KP_9) {
			duty_cycle_mode = (duty_cycle_mode + 1) % 4
		}
		if rl.IsKeyPressed(.KP_5) {
			harmonics -= 1
		}
		if rl.IsKeyPressed(.KP_6) {
			harmonics += 1
		}

		rl.DrawText(
			rl.TextFormat("DC: %i, Harmonics: %f", duty_cycle_mode, harmonics),
			10,
			screen_height - 50,
			20,
			rl.WHITE,
		)
	}
	audio_quit()
}

audio_quit :: proc() {
	ma.device_stop(&app.device)
	ma.device_uninit(&app.device)
}

audio_callback :: proc(device: ^ma.device, output, input: rawptr, frame_count: u32) {
	buffer_size := int(frame_count * OUTPUT_NUM_CHANNELS)

	// get device buffer
	device_buffer := mem.slice_ptr((^f32)(output), buffer_size)

	// if there are enough samples written to the ring buffer to fill the device buffer, read them
	if app.ring_buffer.written > buffer_size {
		sync.lock(&app.mutex)
		buffer_read(device_buffer, &app.ring_buffer, true)
		sync.unlock(&app.mutex)
	}

	// if the ring buffer is at least half empty, tell the sampler generator to start up again
	if app.ring_buffer.written < len(app.ring_buffer.data) / 2 do sync.sema_post(&app.sema)
}

Channel :: struct {
	time_start:   f32, // not used rn
	time_end:     f32, // not used rn
	freq:         f32,
	is_pressed:   bool,
	last_amp:     f32,
	is_releasing: bool,
	last_sample:  f32,
}

channels: []Channel


do_adsr :: proc(channel: ^Channel, time: f64) -> f32 {

	time_to_max :: 0.1 // in seconds. how much time for maximum amplitude
	time_sample :: 1 / f32(OUTPUT_SAMPLE_RATE)
	increment := map_range(time_sample, 0, time_to_max, 0, 1)

	// do ads or release?

	// envelope
	diff_time := f32(time) - channel.time_start

	amp: f32 = 0

	attack_time :: 0.001
	attack_amp :: 1
	decay_time :: 0.2
	sustain_amp :: 0

	do_ads: bool = false

	wants_to_attack: bool


	if channel.is_pressed {

		// wait to go into attack when the last amp is close to 0
		if (channel.is_releasing && math.abs(channel.last_amp) <= 0.001) {
			do_ads = true
			channel.time_start = f32(time)
			diff_time = 0
		} else if channel.is_releasing {
			// accelerate release flag
			wants_to_attack = true
		}

		if (!channel.is_releasing) {
			do_ads = true
		}
	}

	if do_ads {
		// it's on attack?
		if diff_time <= attack_time {
			// calculate attack
			amp = map_range(diff_time, 0, attack_time, 0, attack_amp)
		} else {
			// calculate sustain
			amp = map_range(diff_time - attack_time, 0, decay_time, attack_amp, sustain_amp)

			if amp < sustain_amp {
				amp = sustain_amp
			}
		}
		channel.is_releasing = false
	} else {

		// accelerate release if you want to attack
		if wants_to_attack {
			amp = channel.last_amp - (increment * 3)
		} else {
			amp = channel.last_amp - increment
		}
	}

	amp = math.clamp(amp, 0, 1)
	return amp
}

sample_generator_thread_proc :: proc(data: rawptr) {
	// cast the "data" we passed into the thread to an ^App
	a := (^App)(data)

	channels = make([]Channel, 8)

	// loop infinitely in this new thread
	for {

		// we only want write new samples if there is enough "free" space in the ring buffer
		// so stall the thread if we've filled over half the buffer
		// and wait until the audio callback calls sema_post()
		for a.ring_buffer.written > len(app.ring_buffer.data) / 2 do sync.sema_wait(&a.sema)

		// processing key events
		data, ok := chan.try_recv(data_channel)
		if ok {
			if data.pressed {
				channels[data.key].time_start = f32(a.time)
				channels[data.key].freq = data.freq
				channels[data.key].is_pressed = true
			} else {
				channels[data.key].time_end = f32(a.time)
				channels[data.key].is_pressed = false
				channels[data.key].is_releasing = true
			}
		}

		sync.lock(&a.mutex)
		for i in 0 ..< a.buffer_size {

			total_sample: f32 = 0

			for &channel in channels {
				amp := do_adsr(&channel, a.time)
				channel.last_amp = amp


				//do square wave here
				// sample := sample_square_wave(channel.freq, a.time) * amp
				sample := sample_triangle_wave(channel.freq, a.time) * amp

				// sample :f64 = math.sin_f64(math.PI * 2 * f64(channel.freq) * a.time) * f64(amp)
				channel.last_sample = f32(sample)
				total_sample += f32(sample)
			}

			total_sample /= 3
			buffer_write_sample(&a.ring_buffer, total_sample, true)

			// advance the time
			a.time += 1 / f64(OUTPUT_SAMPLE_RATE)
		}
		sync.unlock(&a.mutex)
	}
}

get_duty_cycle :: proc(mode: int) -> f32 {
	duty_cycle: f32
	switch mode {
	case 0:
		duty_cycle = 0.125
	case 1:
		duty_cycle = 0.25
	case 2:
		duty_cycle = 0.50
	case 3:
		duty_cycle = 0.75
	}

	return duty_cycle
}

// perfect triangle wave
sample_triangle_wave :: proc(freq: f32, time: f64) -> f32 {
	period: f32 = 1 / freq
	top := f32(time) / period
	return 2 * math.abs(2 * (top - math.floor(top + 0.5))) - 1
}


// perfect square wave
sample_square_wave :: proc(freq: f32, time: f64) -> f32 {

	duty_cycle := get_duty_cycle(duty_cycle_mode)

	period: f32 = 1 / freq
	val: f32 = 0

	a := math.mod(f32(time), period)

	fmt.printfln("a %v > dc * p: %v", a, a < duty_cycle * period)

	if a >= 0 && a < duty_cycle * period {
		val = 1
	} else {
		val = -1
	}

	return val
}


sample_square_wave_complex :: proc(freq: f32, time: f64) -> f32 {

	a, b: f32
	p: f32 = get_duty_cycle(duty_cycle_mode) * 2 * 3.14159


	for n in 1 ..< harmonics {

		n_f := f32(n)

		c := n_f * freq * 2 * 3.14159 * f32(time)
		a += math.sin(c) / n_f
		b += math.sin(c - p * n_f) / n_f
	}

	val := (2 / 3.14159) * (a - b)

	return val
}

// simple ring buffer
Buffer :: struct {
	data:      []f32,
	written:   int,
	write_pos: int,
	read_pos:  int,
}

buffer_init :: proc(b: ^Buffer, size: int) {
	b.data = make([]f32, size)
}

// this writes a single sample of data to the buffer, overwriting what was previously there
buffer_write_sample :: proc(b: ^Buffer, sample: f32, advance_pos: bool) {
	buffer_write_slice(b, {sample}, advance_pos)
}

// this writes a slice data to the buffer, overwriting what was previously there
buffer_write_slice :: proc(b: ^Buffer, data: []f32, advance_pos: bool) {
	assert(len(b.data) - b.written > len(data))
	write_pos := b.write_pos
	for di in 0 ..< len(data) {
		write_pos += 1
		if write_pos >= len(b.data) do write_pos = 0
		b.data[write_pos] = data[di]
	}

	if advance_pos {
		b.written += len(data)
		b.write_pos = write_pos
	}
}

// this reads data from the buffer and copies it into the dst slice
buffer_read :: proc(dst: []f32, b: ^Buffer, advance_index: bool = true) {
	read_pos := b.read_pos
	for di in 0 ..< len(dst) {
		read_pos += 1
		if read_pos >= len(b.data) do read_pos = 0
		dst[di] = b.data[read_pos]
		b.data[read_pos] = 0
	}

	if advance_index {
		b.written -= len(dst)
		b.read_pos = read_pos
	}
}

map_range :: proc(x, a, b, c, d: f32) -> f32 {
	return c + (((x - a) * (d - c)) / (b - a))
}
