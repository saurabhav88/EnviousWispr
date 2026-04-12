#!/usr/bin/env python3
"""Apple Intelligence polish test across 20 languages x 3 utterance types.
Uses Google Cloud Chirp3-HD TTS (natural voices) and native-language disfluencies."""
import os, subprocess, sys, time, threading, json, base64, urllib.request, urllib.parse, tempfile
sys.path.insert(0, '/Users/m4pro_sv/Desktop/EnviousWispr/Tests/UITests')
import simulate_input as si

APP_LOG = os.path.expanduser("~/Library/Logs/EnviousWispr/app.log")
SA = json.load(open(os.path.expanduser('~/.enviouswispr-keys/business-workspace-admin-sa.json')))

def b64u(d): return base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b'=').decode()

def get_gcp_token():
    header = {'alg': 'RS256', 'typ': 'JWT', 'kid': SA['private_key_id']}
    now = int(time.time())
    claims = {'iss': SA['client_email'], 'scope': 'https://www.googleapis.com/auth/cloud-platform',
              'aud': 'https://oauth2.googleapis.com/token', 'iat': now, 'exp': now + 3600}
    signing_input = (b64u(header) + '.' + b64u(claims)).encode()
    with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as f:
        f.write(SA['private_key'])
        pem = f.name
    proc = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', pem], input=signing_input, capture_output=True)
    os.unlink(pem)
    sig = base64.urlsafe_b64encode(proc.stdout).rstrip(b'=').decode()
    jwt = signing_input.decode() + '.' + sig
    data = urllib.parse.urlencode({'grant_type':'urn:ietf:params:oauth:grant-type:jwt-bearer','assertion':jwt}).encode()
    with urllib.request.urlopen(urllib.request.Request('https://oauth2.googleapis.com/token', data=data), timeout=20) as r:
        return json.loads(r.read())['access_token']

TOKEN = get_gcp_token()
TOKEN_ISSUED = time.time()

def refresh_token_if_needed():
    global TOKEN, TOKEN_ISSUED
    if time.time() - TOKEN_ISSUED > 3000:
        TOKEN = get_gcp_token()
        TOKEN_ISSUED = time.time()

# (lang_code, locale, voice, tier)
LANGS = [
    ("en", "en-US",  "en-US-Chirp3-HD-Achernar",  "official"),
    ("es", "es-ES",  "es-ES-Chirp3-HD-Achernar",  "official"),
    ("fr", "fr-FR",  "fr-FR-Chirp3-HD-Achernar",  "official"),
    ("de", "de-DE",  "de-DE-Chirp3-HD-Achernar",  "official"),
    ("it", "it-IT",  "it-IT-Chirp3-HD-Achernar",  "official"),
    ("pt", "pt-BR",  "pt-BR-Chirp3-HD-Achernar",  "official"),
    ("ja", "ja-JP",  "ja-JP-Chirp3-HD-Achernar",  "official"),
    ("ko", "ko-KR",  "ko-KR-Chirp3-HD-Achernar",  "official"),
    ("zh", "cmn-CN", "cmn-CN-Chirp3-HD-Achernar", "official"),
    ("vi", "vi-VN",  "vi-VN-Chirp3-HD-Achernar",  "official"),
    ("hi", "hi-IN",  "hi-IN-Chirp3-HD-Achernar",  "unofficial"),
    ("ta", "ta-IN",  "ta-IN-Chirp3-HD-Achernar",  "unofficial"),
    ("ar", "ar-XA",  "ar-XA-Chirp3-HD-Achernar",  "unofficial"),
    ("he", "he-IL",  "he-IL-Chirp3-HD-Achernar",  "unofficial"),
    ("ru", "ru-RU",  "ru-RU-Chirp3-HD-Aoede",     "unofficial"),
    ("uk", "uk-UA",  "uk-UA-Chirp3-HD-Achernar",  "unofficial"),
    ("tr", "tr-TR",  "tr-TR-Chirp3-HD-Achernar",  "unofficial"),
    ("nl", "nl-NL",  "nl-NL-Chirp3-HD-Achernar",  "unofficial"),
    ("pl", "pl-PL",  "pl-PL-Chirp3-HD-Achernar",  "unofficial"),
    ("th", "th-TH",  "th-TH-Chirp3-HD-Achernar",  "unofficial"),
]

UTTERANCES = {
    "en": ("um, send Sarah a message saying, uh, I'll be like, about ten minutes late, you know",
           "uh, remind me tomorrow",
           "okay so for the trip I need um my passport and my charger and uh my headphones and oh yeah my sunglasses too"),
    "es": ("eh, envía un mensaje a Sara, o sea, diciéndole que, pues, llegaré como diez minutos tarde",
           "eh, recuérdame mañana",
           "bueno para el viaje necesito este mi pasaporte y mi cargador y eh mis auriculares y ah sí mis gafas de sol"),
    "fr": ("euh, envoie un message à Camille, ben, pour dire que, genre, j'arriverai dix minutes en retard",
           "euh, rappelle-moi demain",
           "alors pour le voyage il me faut euh mon passeport et mon chargeur et ben mes écouteurs et ah oui mes lunettes de soleil"),
    "de": ("ähm, schick Sara eine Nachricht, also, dass ich, halt, zehn Minuten später komme",
           "äh, erinnere mich morgen",
           "also für die Reise brauche ich ähm meinen Pass und mein Ladegerät und äh meine Kopfhörer und ach ja meine Sonnenbrille"),
    "it": ("ehm, manda un messaggio a Giulia, cioè, per dirle che, allora, arriverò tipo dieci minuti in ritardo",
           "ehm, ricordamelo domani",
           "allora per il viaggio mi servono ehm il passaporto e il caricabatterie e cioè le cuffie e ah sì gli occhiali da sole"),
    "pt": ("é, manda uma mensagem pra Sara, tipo, dizendo que eu vou chegar, sei lá, uns dez minutos atrasado",
           "é, me lembra amanhã",
           "então pra viagem eu preciso do meu passaporte e do carregador e tipo dos meus fones e ah sim dos óculos de sol"),
    "ja": ("えっと、サラに、あの、十分ほど遅れるって送って",
           "あの、明日思い出させて",
           "えーと、旅行にはパスポートと、あの、充電器とヘッドホンと、そうそう、サングラスも要る"),
    "ko": ("어, 사라한테, 그, 십 분 정도 늦는다고 메시지 보내줘",
           "어, 내일 알려줘",
           "음, 여행에는 여권이랑, 그, 충전기랑 헤드폰이랑, 아 맞다, 선글라스도 필요해"),
    "zh": ("呃，给莎拉发条消息，就是，告诉她我，那个，大概晚十分钟",
           "呃，明天提醒我",
           "那个，旅行要带护照还有充电器还有耳机还有，对了，墨镜"),
    "vi": ("ờ, nhắn cho Sara là, à, tôi sẽ đến muộn khoảng mười phút",
           "à, nhắc tôi ngày mai",
           "ừm, chuyến đi tôi cần hộ chiếu với bộ sạc với tai nghe với à ừ kính râm"),
    "hi": ("मतलब, सारा को मैसेज भेजो कि, अच्छा, मुझे लगभग दस मिनट की देरी होगी",
           "अच्छा, कल याद दिलाओ",
           "तो सफर के लिए मुझे पासपोर्ट और चार्जर और हेडफोन और हाँ धूप का चश्मा चाहिए"),
    "ta": ("அது, சாராவுக்கு மெசேஜ் அனுப்பு, என்ன, நான் பத்து நிமிடம் தாமதமாக வருவேன் என்று",
           "அது, நாளை நினைவூட்டு",
           "சரி, பயணத்திற்கு பாஸ்போர்ட் மற்றும் சார்ஜர் மற்றும் ஹெட்ஃபோன் மற்றும் ஆமா, சன் கிளாஸ் வேண்டும்"),
    "ar": ("يعني، أرسل رسالة إلى سارة، شوف، أنني سأتأخر حوالي عشر دقائق",
           "يعني، ذكرني غدا",
           "طيب، للرحلة أحتاج جواز السفر والشاحن والسماعات وآه نعم النظارة الشمسية"),
    "he": ("יעני, תשלח לשרה הודעה, זהו, שאני אאחר בערך עשר דקות",
           "אממ, תזכיר לי מחר",
           "אוקיי, לטיול אני צריך את הדרכון ואת המטען ואת האוזניות וא כן את המשקפי שמש"),
    "ru": ("эээ, отправь Саре сообщение, типа, что я опоздаю, ну, примерно на десять минут",
           "эээ, напомни завтра",
           "ну, для поездки мне нужны паспорт и зарядка и, это самое, наушники и а да солнечные очки"),
    "uk": ("ну, надішли Сарі повідомлення, типу, що я запізнюсь хвилин на десять",
           "ну, нагадай завтра",
           "так, для подорожі мені потрібен паспорт і зарядка і типу навушники і а так сонячні окуляри"),
    "tr": ("şey, Sara'ya mesaj gönder, yani, yaklaşık on dakika geç kalacağımı",
           "şey, yarın hatırlat",
           "tamam, gezi için pasaport ve şarj aleti ve yani kulaklık ve ha evet güneş gözlüğü lazım"),
    "nl": ("eh, stuur Sara een bericht, nou, dat ik ongeveer tien minuten later kom",
           "uhm, herinner me morgen",
           "oké, voor de reis heb ik mijn paspoort en oplader en eh koptelefoon en oh ja zonnebril nodig"),
    "pl": ("yyy, wyślij wiadomość do Sary, no wiesz, że spóźnię się jakieś dziesięć minut",
           "yyy, przypomnij mi jutro",
           "dobra, na podróż potrzebuję paszportu i ładowarki i no słuchawek i a tak okularów przeciwsłonecznych"),
    "th": ("เอ่อ, ส่งข้อความบอกซาร่าว่า, อืม, ฉันจะมาสายประมาณสิบนาที",
           "เอ่อ, เตือนฉันพรุ่งนี้",
           "โอเค, สำหรับการเดินทางฉันต้องใช้พาสปอร์ตและที่ชาร์จและอ่าหูฟังและอ๋อแว่นกันแดดด้วย"),
}

def synth(locale, voice, text, out_path):
    refresh_token_if_needed()
    body = json.dumps({
        "input": {"text": text},
        "voice": {"languageCode": locale, "name": voice},
        "audioConfig": {"audioEncoding": "MP3", "sampleRateHertz": 24000},
    }).encode()
    req = urllib.request.Request(
        "https://texttospeech.googleapis.com/v1/text:synthesize",
        data=body,
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        audio_b64 = json.loads(r.read())["audioContent"]
    with open(out_path, "wb") as f:
        f.write(base64.b64decode(audio_b64))

def audio_duration(path):
    try:
        out = subprocess.run(["afinfo", path], capture_output=True, text=True, timeout=5).stdout
        for line in out.splitlines():
            if "estimated duration" in line.lower():
                return float(line.split(":")[1].split()[0])
    except Exception:
        pass
    return None

def run_one(lang, locale, voice, utt_type, sentence):
    mp3 = f"/tmp/pm_{lang}_{utt_type}.mp3"
    synth(locale, voice, sentence, mp3)
    dur = audio_duration(mp3) or 3.0
    size_before = os.path.getsize(APP_LOG) if os.path.exists(APP_LOG) else 0
    def _play():
        time.sleep(0.3)
        subprocess.run(["afplay", mp3], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    t = threading.Thread(target=_play); t.start()
    hold = dur + 1.2
    si.hold_key("rcmd", duration=hold)
    t.join()
    time.sleep(7.0)  # Apple Intelligence can be slow

    with open(APP_LOG) as f:
        f.seek(size_before)
        lines = f.readlines()

    result = {"lang": lang, "locale": locale, "voice": voice, "utt": utt_type,
              "source": sentence, "dur_s": round(dur, 2),
              "lid": None, "conf": None, "tier_decision": None,
              "raw": None, "polished": None, "polish_status": None,
              "skip_reason": None, "provider": None}
    for line in lines:
        if "LID result:" in line:
            part = line.split("LID result:", 1)[1]
            for tok in part.split():
                if tok.startswith("lang="): result["lid"] = tok.split("=", 1)[1]
                if tok.startswith("conf="): result["conf"] = tok.split("=", 1)[1]
                if tok.startswith("tier="): result["tier_decision"] = tok.split("=", 1)[1]
        elif "CORRECTION_DEBUG [RAW ASR]" in line:
            result["raw"] = line.split("CORRECTION_DEBUG [RAW ASR]", 1)[1].strip()
        elif "CORRECTION_DEBUG [LLM Polish] OUT:" in line:
            result["polished"] = line.split("CORRECTION_DEBUG [LLM Polish] OUT:", 1)[1].strip()
            result["polish_status"] = "ran"
        elif "CORRECTION_DEBUG [LLM Polish] no change" in line:
            result["polish_status"] = "no_change"
            result["polished"] = result["raw"]
        elif "LLM polish skipped" in line:
            result["polish_status"] = "skipped"
            result["skip_reason"] = line.split("LLM polish skipped:", 1)[1].strip()
        elif "LLM polish complete:" in line and "provider=" in line:
            result["provider"] = line.split("provider=")[1].split(",")[0].split(")")[0]
    return result

def main():
    out_path = "/tmp/polish_matrix_results.jsonl"
    total = len(LANGS) * 3
    i = 0
    print(f"Running {total} tests ({len(LANGS)} langs x 3 utterances)...", flush=True)
    print(f"Writing results to {out_path}", flush=True)
    results = []
    with open(out_path, "w") as f:
        for code, loc, voice, tier in LANGS:
            normal, short, listp = UTTERANCES[code]
            for utt_type, sentence in [("normal", normal), ("short", short), ("list", listp)]:
                i += 1
                print(f"[{i:2d}/{total}] {code}/{utt_type} ({len(sentence)} chars)...", flush=True)
                try:
                    r = run_one(code, loc, voice, utt_type, sentence)
                    r["tier"] = tier
                    results.append(r)
                    f.write(json.dumps(r, ensure_ascii=False) + "\n")
                    f.flush()
                    polish = r.get("polish_status") or "?"
                    print(f"    lid={r.get('lid') or 'NA'} conf={r.get('conf') or 'NA'} polish={polish} provider={r.get('provider') or 'NA'}", flush=True)
                except Exception as e:
                    print(f"    ERROR: {e}", flush=True)
                    results.append({"lang": code, "utt": utt_type, "error": str(e), "tier": tier})
                time.sleep(1.5)
    print("\nDone. Results in", out_path, flush=True)

if __name__ == "__main__":
    main()
