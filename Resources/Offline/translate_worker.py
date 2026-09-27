"""Local JSON-lines worker. No network calls; models remain warm between subtitles."""
import json
from pathlib import Path
import sys

import ctranslate2
import sentencepiece

ROOT = Path(sys.argv[1]) / "models"
MODELS = {}


def translate_direct(text, source, target):
    pair = f"{source}_{target}"
    if pair not in MODELS:
        path = ROOT / pair
        tokenizer = sentencepiece.SentencePieceProcessor(model_file=str(path / "sentencepiece.model"))
        translator = ctranslate2.Translator(str(path / "model"), device="cpu", compute_type="int8",
                                           inter_threads=1, intra_threads=4)
        metadata = json.loads((path / "metadata.json").read_text())
        MODELS[pair] = (tokenizer, translator, metadata.get("target_prefix", ""))
    tokenizer, translator, prefix = MODELS[pair]
    tokens = tokenizer.encode(text, out_type=str)
    # Subtitle-sized input only; never silently truncate a large screen of text.
    if len(tokens) > 150:
        raise ValueError("字幕过长，请缩小选区至一至两行字幕")
    result = translator.translate_batch([tokens], beam_size=2, max_decoding_length=200,
        replace_unknowns=True, length_penalty=0.2,
        target_prefix=[[prefix]] if prefix else None)[0]
    output = tokenizer.decode(result.hypotheses[0]).replace("▁", " ")
    if prefix and output.startswith(prefix):
        output = output[len(prefix):]
    return output.strip()


def translate(text, source, target):
    if source not in ("en", "zh", "ja") or target not in ("en", "zh", "ja"):
        raise ValueError("不支持的翻译语言")
    if source == target:
        return text
    if source != "en" and target != "en":
        return translate_direct(translate_direct(text, source, "en"), "en", target)
    return translate_direct(text, source, target)


for line in sys.stdin:
    try:
        request = json.loads(line)
        result = translate(request["text"], request["source"], request["target"])
        print(json.dumps({"text": result}, ensure_ascii=False), flush=True)
    except Exception as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), flush=True)
