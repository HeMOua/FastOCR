#include "whisper.h"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

// The parent sends: "<language> <float-sample-count>\n", then mono 16 kHz float32 PCM.
// Only JSON replies go to stdout. No audio files, network calls, or transcript logs.
static std::string quoted(const std::string &text) {
    std::string out = "\"";
    for (unsigned char c : text) {
        switch (c) {
        case '"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 32) { char escaped[7]; std::snprintf(escaped, sizeof(escaped), "\\u%04x", c); out += escaped; }
            else out += static_cast<char>(c);
        }
    }
    return out + "\"";
}
static bool expired(void *data) {
    const auto start = *static_cast<std::chrono::steady_clock::time_point *>(data);
    return std::chrono::steady_clock::now() - start > std::chrono::seconds(10);
}
int main(int argc, char **argv) {
    if (argc != 2) return 2;
    whisper_log_set([](enum ggml_log_level, const char *, void *) {}, nullptr);
    auto contextParams = whisper_context_default_params();
    contextParams.use_gpu = true;
    auto *context = whisper_init_from_file_with_params(argv[1], contextParams);
    if (!context) { std::cout << "{\"error\":\"无法加载本地语音模型，请重新准备模型。\"}" << std::endl; return 3; }
    std::string header;
    while (std::getline(std::cin, header)) {
        std::istringstream parser(header);
        std::string language;
        size_t count = 0;
        if (!(parser >> language >> count) || count < 1600 || count > 16000 * 15 ||
            (language != "auto" && language != "zh" && language != "en" && language != "ja")) break;
        std::vector<float> pcm(count);
        if (!std::cin.read(reinterpret_cast<char *>(pcm.data()), count * sizeof(float))) break;
        double energy = 0;
        for (float &sample : pcm) { if (!std::isfinite(sample)) sample = 0; energy += sample * sample; }
        if (energy / count < 0.000001) { std::cout << "{\"text\":\"\",\"language\":\"\"}" << std::endl; continue; }
        auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
        params.n_threads = 4;
        params.translate = false;
        params.language = language.c_str();
        params.no_context = true;
        params.no_timestamps = true;
        params.single_segment = true;
        params.print_progress = params.print_realtime = params.print_timestamps = params.print_special = false;
        params.suppress_blank = true;
        params.suppress_nst = true;
        params.temperature_inc = 0;
        params.greedy.best_of = 1;
        params.max_tokens = 120;
        auto start = std::chrono::steady_clock::now();
        params.abort_callback = expired;
        params.abort_callback_user_data = &start;
        if (whisper_full(context, params, pcm.data(), static_cast<int>(count)) != 0) {
            std::cout << "{\"error\":\"本段语音识别失败或超时，已跳过。\"}" << std::endl;
            continue;
        }
        std::string text;
        for (int i = 0; i < whisper_full_n_segments(context); ++i) {
            if (whisper_full_get_segment_no_speech_prob(context, i) < 0.65f) text += whisper_full_get_segment_text(context, i);
        }
        const char *detected = whisper_lang_str(whisper_full_lang_id(context));
        std::cout << "{\"text\":" << quoted(text) << ",\"language\":" << quoted(detected ? detected : "") << "}" << std::endl;
    }
    whisper_free(context);
    return 0;
}
