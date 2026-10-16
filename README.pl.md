# Quest 3 Hand Tracking -> Blender Live Streaming System

Kompletna dokumentacja architektury, kodu, formatu danych i podłączania modeli dłoni.

---

## 1. Architektura systemu

System przesyła śledzenie dłoni w czasie rzeczywistym z Meta Quest 3 bezpośrednio do Blendera przez sieć lokalną:

```
[ Meta Quest 3 (Godot 4 XR) ]
        │
        │ UDP (JSON, ~60-90 Hz, port 5005)
        ▼
[ PC: Blender 3.6 / 4.x / 5.x ]
        │
        ├── HandReceiverThread (wątek w tle, gniazdo UDP)
        └── bpy.app.timers (główny wątek Blendera, ~120 Hz)
                └── Aktualizacja Armature & Pose Bones
```

---

## 2. Pliki w projekcie (Gdzie co jest)

### A. Po stronie Godot (Meta Quest 3)
* **[`hand_streamer.gd`](hand_streamer.gd)**
  * Odczytuje dane OpenXR bezpośrednio z `XRHandTracker` (`/user/hand_tracker/left` i `/user/hand_tracker/right`).
  * Zbiera pozycję/orientację głowy (`XRCamera3D`), pozycję/rotację nadgarstka (`HAND_JOINT_WRIST`) oraz hierarchiczne łańcuchy kości palców.
  * Używa dedykowanego wątku roboczego (`Thread` + `Semaphore`), aby wysyłać pakiety bez blokowania klatki VR (~90 FPS).
  * Konfiguracja sieci: plik `user://stream_config.json` w pamięci Questa (IP PC, port, opcja broadcast).
* **[`main_vr.tscn`](main_vr.tscn)** / **[`vr_main.gd`](vr_main.gd)**
  * Główna scena VR z węzłem `XROrigin3D`, kamerą i węzłami dłoni.
* **[`assets/hands/hand_rig.gd`](assets/hands/hand_rig.gd)**
  * Skrypt pomocniczy w Godocie do automatycznego podpinania `XRHandModifier3D` do lokalnych modeli.

### B. Po stronie Blendera (PC)
* **[`blender_addon/blender_hand_receiver.py`](blender_addon/blender_hand_receiver.py)**
  * Odbiornik UDP uruchamiany w Blenderze (zakładka *Scripting* -> *Run Script*).
  * Tworzy wątek nasłuchujący na porcie `5005`.
  * Aktualizuje obiekty typu Armature w scenie Blendera.
  * Posiada wbudowane logowanie w konsoli systemowej (`Window -> Toggle System Console`) z FPS i kątami palców.
* **[`quest_dump.json`](quest_dump.json)**
  * Zrzut rzeczywistej ramki UDP odebranej z Questa (przydatny do testowania bez włączania gogli).

---

## 3. Format danych pakietu UDP (JSON)

Pakiety są wysyłane jako surowy JSON UTF-8 przez UDP na port `5005`:

```json
{
  "time": 377997,
  "head": {
    "pos": [x, y, z],
    "rot": [qx, qy, qz, qw]
  },
  "left": {
    "wrist": {
      "pos": [x, y, z],
      "rot": [qx, qy, qz, qw]
    },
    "chains": {
      "thumb": [
        {"name": "ThumbMetacarpal", "rot": [qx, qy, qz, qw], "length": 0.05},
        {"name": "ThumbProximal",   "rot": [qx, qy, qz, qw], "length": 0.03},
        {"name": "ThumbDistal",     "rot": [qx, qy, qz, qw], "length": 0.03},
        {"name": "ThumbTip",        "rot": [0, 0, 0, 1],     "length": 0.02}
      ],
      "index": [
        {"name": "IndexMetacarpal",   "rot": [0, 0, 0, 1],     "length": 0.04},
        {"name": "IndexProximal",     "rot": [qx, qy, qz, qw], "length": 0.06},
        {"name": "IndexIntermediate", "rot": [qx, qy, qz, qw], "length": 0.04},
        {"name": "IndexDistal",       "rot": [qx, qy, qz, qw], "length": 0.02},
        {"name": "IndexTip",          "rot": [0, 0, 0, 1],     "length": 0.02}
      ],
      "middle": [ ... ],
      "ring":   [ ... ],
      "little": [ ... ]
    }
  },
  "right": {
    "wrist": { ... },
    "chains": { ... }
  }
}
```

### Nazewnictwo kości w strumieniu (Standard OpenXR):
* Kciuk: `ThumbMetacarpal` -> `ThumbProximal` -> `ThumbDistal` -> `ThumbTip`
* Palce (Index, Middle, Ring, Little):
  `Metacarpal` -> `Proximal` -> `Intermediate` -> `Distal` -> `Tip`

W Blenderze skrypt szuka kości z przedrostkiem `Left` lub `Right`, np.:
`RightIndexProximal`, `RightMiddleIntermediate` itp.

---

## 4. Przestrzenie współrzędnych i matematyka

### A. Przestrzeń pokoju (Pozycja nadgarstka):
* **Godot VR Room Space**: Prawoskrętny: `+X` = Prawo, `+Y` = Góra, `-Z` = Przód.
* **Blender World Space**: Prawoskrętny: `+X` = Prawo, `+Y` = Przód, `+Z` = Góra.
* **Przeliczenie translacji**:
  $$\text{Blender}(x, y, z) = (\text{Godot } x, -\text{Godot } z, \text{Godot } y)$$

### B. Orientacja nadgarstka (Rotacja Armature):
Ramki stawów, które faktycznie przychodzą z Godota (sprawdzone na `quest_dump.json`; NIE są to surowe ramki OpenXR):
* `+Y` = wzdłuż kości / palców (konwencja szkieletu Godota)
* `+Z` = WNĘTRZE dłoni (dodatnie `qx` = zgięcie palca)
* `+X` = prawa dłoń: w stronę kciuka, lewa: w stronę małego palca
* Metacarpale Index/Middle/Ring mają zawsze rotację identyczną z nadgarstkiem (Meta nie śledzi ich osobno).

Stary skrypt zakładał surowe OpenXR (`-Z` wzdłuż kości, `+Y` = grzbiet) i zgadywał permutacje kwaternionów – stąd powyginane ręce.
Stara wersja: `blender_hand_receiver_old.py`.

---

## 5. Dlaczego stary model (`BothHands.blend`) sprawiał problemy

1. **Nietypowy Rest Pose ("Karate chop")**:
   * Zwykłe modele dłoni w Blenderze mają palce wyprostowane wzdłuż osi `+Y` lub `+Z` z dłonią skierowaną w dół.
   * W `BothHands.blend` model był zamodelowany bokiem: kciuk w `+Z`, mały palec w `-Z`, a powierzchnia dłoni w osi `X`. Wymagało to sztucznych macierzy obrotu bazy (`M_ALIGN`), które łatwo rozjeżdżały się przy zmianie widoku.
2. **Obrócone osie kości (Bone Roll)**:
   * Kości palców w starym rig-u miały lokalne osie obrócone w taki sposób, że standardowy dodatni kąt zgięcia (flexion) z OpenXR wyginał palce w stronę grzbietu lub rozczapierzał je na boki zamiast zginać do wnętrza dłoni.

---

## 6. Jak podłączyć nowy model dłoni w Blenderze

Gdy pobierzesz lub stworzysz nowy model dłoni:

### Krok 1: Weryfikacja nazewnictwa kości w Armature
Upewnij się, że kości w rig-u nazywają się zgodnie ze schematem (lub zmień nazwy w skrypcie):
* Prawa ręka:
  * `RightHand` (lub kość nadgarstka / root)
  * `RightThumbMetacarpal`, `RightThumbProximal`, `RightThumbDistal`
  * `RightIndexMetacarpal`, `RightIndexProximal`, `RightIndexIntermediate`, `RightIndexDistal`
  * (Analogicznie dla `RightMiddle...`, `RightRing...`, `RightLittle...`)
* Lewa ręka: z przedrostkiem `Left`.

### Krok 2: Sprawdzenie osi zginania (Roll kości)
W trybie **Edit Mode** w Blenderze włącz podgląd osi kości (**Armature Properties -> Viewport Display -> Axes**):
1. Zobacz, wzdłuż której lokalnej osi kość ma długość (zazwyczaj lokalna oś `Y`).
2. Sprawdź, wokół której lokalnej osi palec naturalnie zgina się w pięść (zazwyczaj lokalna oś `X`).

### Krok 3: Nic nie trzeba mapować ręcznie
Od wersji v2 `blender_addon/blender_hand_receiver.py` sam liczy kalibrację z rest pose armatury
(kierunki kości + płaszczyzna dłoni), więc roll kości i orientacja modelu nie mają znaczenia.
Wystarczą poprawne nazwy kości i nazwy obiektów w `ARMATURES` na górze skryptu.

### Krok 4: Uruchomienie i test
1. Wklej skrypt do zakładki **Scripting** nowego pliku `.blend`.
2. Otwórz konsolę: **Window -> Toggle System Console**.
3. Uruchom skrypt (**Alt+P**).
4. Obserwuj żywe logi:
   ```text
   [QuestReceiver] 60 FPS | Nadgarstek pos=(-0.45, 1.02, 0.14) | Wskazujący: +58.5° | Środkowy: +71.8°
   ```
5. Funkcje dostępne w konsoli Pythona Blendera:
   * `stop_stream()` – zatrzymanie wątku i timera.
   * `start_stream()` – ponowne uruchomienie.
   * `save_dump("nazwa.json")` – zrzut aktualnego pakietu do analizy.

---

## 7. Odbiornik v2 – jak to liczy
1. Z rest pose budowana jest ramka nadgarstka `Fw` w konwencji danych (palce `+Y`, wnętrze dłoni `+Z`).
2. Dla każdej kości `Qref` = orientacja, którą Quest zgłosiłby dla dłoni w rest pose modelu.
3. Na żywo: `G` = złożenie `rot` wzdłuż łańcucha, `D = G·Qref⁻¹`, przeniesione do armatury przez `Fw`,
   potem przeliczone na `matrix_basis` z uwzględnieniem rodzica.
4. Obiekt armatury: `world = T(Godot→Blender) · Wrist · Fw⁻¹`.

Funkcje w konsoli Pythona Blendera: `start_stream()`, `stop_stream()`, `save_dump("x.json")`,
`apply_dump("quest_dump.json")` (podgląd bez gogli), `reset_pose()`.
Opcja na górze skryptu: `WORLD_SCALE`. Punkty odniesienia ustawia się w panelu (sekcja 8).

---

## 8. Addon Blendera (v1.2)
`blender_addon/blender_hand_receiver.py` jest teraz addonem.
* Instalacja: *Edit > Preferences > Add-ons > Install from Disk* albo *Scripting > Run Script* (Alt+P).
  Ponowne uruchomienie jest bezpieczne: zatrzymuje działający odbiornik i przerejestrowuje klasy.
* Panel: *3D Viewport > pasek N > własna zakładka Quest Hands* (pod zakładką Animation).
* **Right Hand / Left Hand** – wybór armatury z listy (tylko obiekty typu Armature). Prefiks kości wykrywany automatycznie (`Right…`, `Left…` albo dowolny `<X>IndexProximal`).
* **Head** – dowolny obiekt (Empty, Camera…): pozycja + rotacja gogli. Osie jak Camera w Blenderze: lokalne `-Z` = kierunek patrzenia, `+Y` = góra. Skala obiektu zostaje.
* **Rig: Auto / Native / Geometric**
  * *Native* – osie kości rigu są w konwencji danych Questa (+Y wzdłuż kości, +Z wnętrze dłoni), jak `RightHandHumanoid`/`LeftHandHumanoid` z Godota. Obroty z Questa idą wprost na kości (jak `XRHandModifier3D` w goglach) – wynik identyczny z tym, co widać w headsecie.
  * *Geometric* – dowolny rig: kalibracja z geometrii rest pose (roll kości bez znaczenia), metacarpale palców zamrożone (`FREEZE_FINGER_METACARPALS`).
  * *Auto* – Native, gdy osie Z kości palców odbiegają od strony dłoni średnio < `NATIVE_MAX_DEG` (20°), inaczej Geometric. Wykryty tryb widać w panelu.
* **Head Origin** – obiekt będący punktem zerowym przestrzeni Questa dla głowy (lokacja + rotacja, skala ignorowana). Puste = środek świata.
* **Hands relative to Head** (domyślnie włączone) – dłonie liczone względem obiektu Head: `dłoń = Head · głowa_pokój⁻¹ · dłoń_pokój`, więc podążają za Head, nawet gdy Head jest przesunięty czymś innym (constraint, rig).
* **Hands Origin** – gdy powyższe wyłączone: punkt zerowy dla dłoni. Puste = środek świata.
* Kotwicą nie może być obiekt, który addon sam ustawia (dłonie, Head).
* Wybór zapisuje się w pliku `.blend` (właściwości sceny).
* **Start** – nie wystartuje, jeśli nie wybrano żadnej dłoni, obie wskazują tę samą armaturę, rig nie ma kości dłoni albo port UDP jest zajęty.
* **Stop** – wysyła na `127.0.0.1:5005` pakiet-killer (`QUEST_RECEIVER_KILL:<token>`), wątek kończy się natychmiast.

---

## 9. Format pakietu UDP: binarny QHND v1 (domyślny od v1.7)
`hand_streamer.gd`: `use_binary = true` (domyślnie). `false` = stary JSON. Addon Blendera rozpoznaje oba automatycznie.

Little-endian, stała kolejność 24 stawów (jak `FINGER_CHAINS`: thumb 4, index 5, middle 5, ring 5, little 5):

| Blok | Zawartość | Rozmiar |
|---|---|---|
| nagłówek | `"QHND"`, u8 wersja=1, u8 flagi, u16 liczba stawów, u32 czas ms | 12 B |
| głowa (flaga bit0) | pos xyz, rot xyzw (f32) | 28 B |
| dłoń lewa (bit1), potem prawa (bit2) | u32 maska ważności stawów, nadgarstek pos+rot (7×f32), 24 × (rot xyzw, pos xyz) | 704 B |
| `model_rot` (bit3, debug) | 24 × rot xyzw dla każdej obecnej dłoni | 384 B / dłoń |

* Obie dłonie bez `model_rot`: **1448 B** – mieści się w jednym datagramie (MTU). Z `model_rot`: 2216 B (wyłącz `send_model_bones`, gdy debug niepotrzebny).
* Brak dłoni = brak bloku (flaga 0). W Blenderze opcja **Inactive hand: Hold / Hide / Rest**.
* Maska ważności: bit = staw i jego rodzic mają ważną orientację i pozycję (`get_hand_joint_flags`). Nieważne stawy w Blenderze trzymają ostatnią ważną wartość.
* Nieznana wersja / śmieci → pakiet odrzucany, licznik `bad` w statusie panelu.

---

## 10. Bone length: From Quest vs From model – po ludzku

Każdy staw dłoni to dwie informacje:
1. **w którą stronę jest obrócony** (zgięcie palca),
2. **gdzie dokładnie się znajduje** (np. jak daleko kostka jest od nadgarstka).

Obroty zawsze biorą się z Questa. Przełącznik decyduje tylko o **pozycjach stawów**:

* **From Quest** – pozycje też z Questa. Kości w Blenderze dostają długości **twojej prawdziwej dłoni** (jak model w goglach, `BONE_UPDATE_FULL`). Dłoń wygląda 1:1 jak w headsecie, łącznie z nasadą małego palca. Model może się trochę rozciągnąć albo skurczyć, jeśli twoja dłoń ma inny rozmiar niż model.
  → używaj dla ludzkiej dłoni, gdy ma wyglądać dokładnie jak twoja.
* **From model** – pozycje i długości kości zostają **z modelu**, Quest tylko zgina palce. Dłoń zachowuje proporcje postaci (np. długie szpony smoka nie skrócą się do ludzkich palców).
  → używaj dla postaci o innych proporcjach niż twoja dłoń.

Stary APK bez pozycji w pakiecie = automatycznie działa jak *From model*.

Debug `model_rot` jest domyślnie wyłączony (`send_model_bones = false` w `hand_streamer.gd`) – pakiet z obiema dłońmi ma 1448 B i mieści się w jednym datagramie.

---

## 11. Struktura repozytorium (publiczna)
| Ścieżka | Zawartość |
|---|---|
| `blender_addon/blender_hand_receiver.py` | addon Blendera „Oculus Quest Hand Tracking” |
| `blender_scripts/` | skrypty pomocnicze do retargetu na rig Mixamo (`mixamo_arm_setup.py`, `mixamo_finger_constraints.py`, `mixamo_thumb_fix.py`) |
| `make_release.py` | buduje `releases/OculusQuestHandTracking_<tag>.zip` (Install from Disk) |
| `*.gd`, `*.tscn`, `project.godot` | aplikacja Godot 4 na Quest 3 |
| `assets/hands/` | modele dłoni (glTF) |
| `blender_models/` | sceny testowe Blendera |

Dumpy debug (`quest_dumps/`, `quest_last_frames.jsonl`) zapisują się obok zapisanego pliku `.blend` (albo w `~/QuestHandTracking`).
