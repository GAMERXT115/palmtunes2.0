package com.palmtunes.hands;

import android.media.MediaCodec;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.FloatBuffer;
import java.nio.ShortBuffer;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * Bass analyzer for Android.
 *
 * Dart calls "envelope" with a file path. The audio track is decoded with
 * MediaCodec, mixed down to mono, thinned to about 8 kHz, run through the same
 * 3-pole 150 Hz low-pass the desktop meter used, and the RMS level in dB is
 * reported once per window (20 ms). The result is a double[] (a Float64List in
 * Dart).
 */
public class PalmtunesHandsPlugin implements FlutterPlugin, MethodCallHandler {
    private static final double CUTOFF_HZ = 150.0;
    private static final int TARGET_RATE = 8000;
    private static final int POLES = 3;

    private MethodChannel channel;
    private final ExecutorService executor = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        channel = new MethodChannel(binding.getBinaryMessenger(), "palmtunes/bass");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull final Result result) {
        if (!"envelope".equals(call.method)) {
            result.notImplemented();
            return;
        }
        final String path = call.argument("path");
        Double w = call.argument("windowMs");
        final double windowMs = w == null ? 20.0 : w;
        if (path == null) {
            result.error("args", "path is missing", null);
            return;
        }
        executor.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    final double[] env = analyze(path, windowMs);
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            result.success(env);
                        }
                    });
                } catch (final Throwable t) {
                    main.post(new Runnable() {
                        @Override
                        public void run() {
                            result.error("analyze", String.valueOf(t.getMessage()), null);
                        }
                    });
                }
            }
        });
    }

    // ---- analysis ---------------------------------------------------------

    private static final class Dsp {
        final double alpha;
        final int decim;
        final int windowSamples;
        final double[] state = new double[POLES];
        double sum = 0;
        int count = 0;
        double acc = 0;
        int accCount = 0;
        double[] out = new double[4096];
        int outLen = 0;

        Dsp(int sampleRate, double windowMs) {
            decim = Math.max(1, sampleRate / TARGET_RATE);
            double fs = sampleRate / (double) decim;
            alpha = 1.0 - Math.exp(-2.0 * Math.PI * CUTOFF_HZ / fs);
            windowSamples = Math.max(1, (int) Math.round(fs * windowMs / 1000.0));
        }

        /** One mono sample, -1..1. */
        void add(double mono) {
            acc += mono;
            accCount++;
            if (accCount < decim) return;
            double v = acc / accCount;
            acc = 0;
            accCount = 0;
            for (int i = 0; i < POLES; i++) {
                state[i] += alpha * (v - state[i]);
                v = state[i];
            }
            sum += v * v;
            count++;
            if (count >= windowSamples) {
                double rms = Math.sqrt(sum / count);
                push(20.0 * Math.log10(rms + 1e-9));
                sum = 0;
                count = 0;
            }
        }

        void push(double db) {
            if (outLen == out.length) {
                double[] bigger = new double[out.length * 2];
                System.arraycopy(out, 0, bigger, 0, outLen);
                out = bigger;
            }
            out[outLen++] = db;
        }

        double[] result() {
            double[] r = new double[outLen];
            System.arraycopy(out, 0, r, 0, outLen);
            return r;
        }
    }

    private static double[] analyze(String path, double windowMs) throws Exception {
        MediaExtractor extractor = new MediaExtractor();
        MediaCodec codec = null;
        try {
            extractor.setDataSource(path);
            int track = -1;
            MediaFormat format = null;
            String mime = null;
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                MediaFormat f = extractor.getTrackFormat(i);
                String m = f.getString(MediaFormat.KEY_MIME);
                if (m != null && m.startsWith("audio/")) {
                    track = i;
                    format = f;
                    mime = m;
                    break;
                }
            }
            if (track < 0) throw new IllegalStateException("No audio track");
            extractor.selectTrack(track);

            codec = MediaCodec.createDecoderByType(mime);
            codec.configure(format, null, null, 0);
            codec.start();

            int sampleRate = format.containsKey(MediaFormat.KEY_SAMPLE_RATE)
                    ? format.getInteger(MediaFormat.KEY_SAMPLE_RATE) : 44100;
            int channels = format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)
                    ? format.getInteger(MediaFormat.KEY_CHANNEL_COUNT) : 2;
            boolean floatPcm = false;
            Dsp dsp = new Dsp(sampleRate, windowMs);

            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            boolean inputDone = false;
            boolean outputDone = false;

            while (!outputDone) {
                if (!inputDone) {
                    int inIndex = codec.dequeueInputBuffer(10000);
                    if (inIndex >= 0) {
                        ByteBuffer in = codec.getInputBuffer(inIndex);
                        int size = in == null ? -1 : extractor.readSampleData(in, 0);
                        if (size < 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, 0,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputDone = true;
                        } else {
                            codec.queueInputBuffer(inIndex, 0, size, extractor.getSampleTime(), 0);
                            extractor.advance();
                        }
                    }
                }

                int outIndex = codec.dequeueOutputBuffer(info, 10000);
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    MediaFormat nf = codec.getOutputFormat();
                    int newRate = nf.containsKey(MediaFormat.KEY_SAMPLE_RATE)
                            ? nf.getInteger(MediaFormat.KEY_SAMPLE_RATE) : sampleRate;
                    int newCh = nf.containsKey(MediaFormat.KEY_CHANNEL_COUNT)
                            ? nf.getInteger(MediaFormat.KEY_CHANNEL_COUNT) : channels;
                    floatPcm = nf.containsKey("pcm-encoding") && nf.getInteger("pcm-encoding") == 4;
                    if (newRate != sampleRate) {
                        // Rebuild the filter for the real output rate, keeping what we have.
                        double[] have = dsp.result();
                        dsp = new Dsp(newRate, windowMs);
                        for (double d : have) dsp.push(d);
                    }
                    sampleRate = newRate;
                    channels = Math.max(1, newCh);
                } else if (outIndex >= 0) {
                    ByteBuffer out = codec.getOutputBuffer(outIndex);
                    if (out != null && info.size > 0) {
                        out.position(info.offset);
                        out.limit(info.offset + info.size);
                        out.order(ByteOrder.nativeOrder());
                        if (floatPcm) {
                            FloatBuffer fb = out.asFloatBuffer();
                            while (fb.remaining() >= channels) {
                                double sum = 0;
                                for (int c = 0; c < channels; c++) sum += fb.get();
                                dsp.add(sum / channels);
                            }
                        } else {
                            ShortBuffer sb = out.asShortBuffer();
                            while (sb.remaining() >= channels) {
                                double sum = 0;
                                for (int c = 0; c < channels; c++) sum += sb.get();
                                dsp.add(sum / channels / 32768.0);
                            }
                        }
                    }
                    codec.releaseOutputBuffer(outIndex, false);
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) outputDone = true;
                }
            }
            return dsp.result();
        } finally {
            try {
                if (codec != null) {
                    codec.stop();
                    codec.release();
                }
            } catch (Throwable ignored) {
            }
            extractor.release();
        }
    }
}
