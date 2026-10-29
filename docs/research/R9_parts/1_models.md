# R9, часть 1. Модели и библиотеки распознавания лица для Flutter (Windows, Android, iOS) — локально, без облака

Дата: 2026-10-26. Этап «исследование и проект изменения ТЗ»: код не пишется, утверждённое ТЗ (`docs/specification/`) и ядро решений (`docs/research/R0_DECISION_KERNEL.md`) этот документ не меняет.

Повод: заказчик 2026-10-26 выбрал «собственное распознавание лица в приложении» — регистрацию и вход по лицу. Сейчас действует D-13: только системная биометрия, приложение биометрию не собирает и не хранит. Сравнение с действующим решением, юридическая часть, защита от подделки (PAD/liveness) и серверная архитектура разбираются в других частях R9. Здесь — только технологии: модели, движки вывода, камера, готовые SDK.

Легенда статусов (как в R6):
- **[ПОДТВЕРЖДЕНО: источник]** — проверено по первоисточнику (дата обращения ко всем URL — 2026-10-26);
- **[ВТОРИЧНЫЙ ИСТОЧНИК]** — данные агрегатора, реселлера или зеркала, у производителя не проверены;
- **[НЕЯСНО]** — источники молчат или противоречат друг другу; нужен письменный ответ правообладателя или прототип.

Даты публикации пакетов на pub.dev показаны там только относительно («N дней назад»). Ниже они пересчитаны от 2026-10-26 и помечены «≈».

Ограничения исследования: модели не запускались, замеры на кассах заказчика не делались; скорость приводится только по опубликованным бенчмаркам. Цены коммерческих SDK почти везде — «по запросу».

---

## 0. Сводка

| № | Вывод | Статус |
|---|---|---|
| 1 | Единственная связка с **явно разрешающими лицензиями и на код, и на веса** и с готовой обвязкой для Dart на всех трёх платформах — **YuNet (MIT) + SFace (Apache-2.0) из OpenCV Zoo через `opencv_dart` 2.2.2 (Apache-2.0)**. Пакет требует Dart 3.10 / Flutter 3.38, это совпадает с проектом (Flutter 3.38.7 / Dart 3.10.7) | [ПОДТВЕРЖДЕНО: OpenCV Zoo, pub.dev] |
| 2 | Модели InsightFace (ArcFace, buffalo_*, antelopev2): код под MIT, но **веса — «только для некоммерческих исследований»**. Для коммерческого POS без отдельного договора с InsightFace **недопустимы** | [ПОДТВЕРЖДЕНО: README InsightFace] |
| 3 | Точные лёгкие модели (EdgeFace, MobileFaceNet, FaceNet, AdaFace) обучены на наборах с некоммерческими или неясными условиями (WebFace260M, MS-Celeb-1M, VGGFace2, CASIA-WebFace). У EdgeFace лицензии противоречат друг другу: на GitHub BSD-3-Clause, на Hugging Face CC-BY-NC-SA-4.0 | [НЕЯСНО] — без юриста не брать |
| 4 | **Главное техническое препятствие — камера на Windows.** `camera_windows` не отдаёт кадры в Dart: поддержку потока добавили в 0.2.5, а в 0.2.6 откатили. `camera_desktop` 2.0.0 поток на Windows даёт, но требует Dart ≥ 3.11 (Flutter ≥ 3.41), то есть обновления Flutter относительно утверждённого стека | [ПОДТВЕРЖДЕНО: pub.dev] |
| 5 | MediaPipe Face Detector: только Android, iOS, Web, Python, **без Windows**. ML Kit: только Android и iOS и **только детекция** (лицо не распознаёт). В модельной карточке BlazeFace распознавание личности прямо названо вне назначения модели | [ПОДТВЕРЖДЕНО: Google] |
| 6 | Движок ONNX для Flutter на всех трёх платформах — `flutter_onnxruntime` 1.9.0 (MIT, ONNX Runtime 1.28.x, ≈ 2026-10-06). `tflite_flutter` 0.12.1 на Windows требует вручную собранной DLL, последний выпуск ≈ 12 месяцев назад | [ПОДТВЕРЖДЕНО: pub.dev] |
| 7 | Готовые SDK с офлайн-распознаванием и liveness, где **Windows, Android и iOS** заявлены вместе: Luxand FaceSDK 9.0.1 и Neurotechnology VeriLook. Официальной Flutter-обвязки на все три платформы нет ни у одного: нужен FFI или platform channel. Regula, FaceTec, 3DiVi, KBY-AI, Paravision в Flutter — только Android и iOS, либо liveness у них серверный | [ПОДТВЕРЖДЕНО / ВТОРИЧНЫЙ — по строкам §5] |
| 8 | Открытой модели liveness с независимой сертификацией (iBeta / ISO/IEC 30107-3) не найдено. Есть MiniFASNet (Silent-Face-Anti-Spoofing, Apache-2.0, 2020 г.) с метриками от самого автора. Сертифицированный PAD (Luxand заявляет iBeta Level 1&2) — только в коммерческих SDK | [ПОДТВЕРЖДЕНО / ВТОРИЧНЫЙ] |

Рекомендуемые стеки (обоснование — §6):
- **A (базовый, открытый):** `opencv_dart` + YuNet + SFace. Камера: `camera` на Android/iOS; на Windows — по итогам прототипа.
- **B (открытый, гибкий):** `flutter_onnxruntime` + YuNet + модель эмбеддинга, выбранная после юридической проверки. До проверки — та же SFace в ONNX.
- **C (коммерческий):** Luxand FaceSDK или Neurotechnology VeriLook через FFI или platform channel. Это единственный путь к сертифицированному liveness на Windows.

---

## 1. Детекция лица

| Модель / библиотека | Лицензия кода | Лицензия весов | Коммерческое использование | Точность | Размер | Скорость CPU | Платформы во Flutter |
|---|---|---|---|---|---|---|---|
| **YuNet** (OpenCV Zoo, `face_detection_yunet_2023mar.onnx`; в 2026 г. добавлена `2026may` с динамическим входом) | MIT | MIT («All files in this directory are licensed under MIT License») | **Да** (MIT). Оговорка: обучена на WIDER FACE, а у этого набора, по зеркалу на Hugging Face, лицензия CC-BY-NC-ND-4.0 — [НЕЯСНО], переходят ли условия набора на веса | WIDER Face val AP: 0.834 / 0.824 / 0.708 (easy/medium/hard) во введении; 0.8844 / 0.8656 / 0.7503 в таблице `tools/eval`. Расхождение на странице не объяснено | ≈ 75 тыс. параметров [ВТОРИЧНЫЙ: Luxonis, HF]; файл 338 КБ [ВТОРИЧНЫЙ: пересказ туториала OpenCV, сама страница вернула 403] | Intel i7-12700K: 0.69 мс fp32 / 0.79 мс int8; Raspberry Pi 4B: 6.23 / 6.68 мс; RK3588: 2.30 / 2.70 мс (OpenCV, CPU, среднее с пре- и постобработкой) | Windows, Android, iOS — через `opencv_dart` (`FaceDetectorYN`) или ONNX Runtime |
| **BlazeFace** (MediaPipe Face Detector: short-range, full-range, sparse full-range) | Apache-2.0 (примеры кода) | Apache-2.0 (модельная карточка short-range) | Лицензия разрешает. Но в карточке: «Any form of surveillance or identity recognition is explicitly out of scope». Для распознавания личности модель не предназначена | AP в карточке есть, сводное число в источнике не выделено | 224 КБ (short-range), вход 128×128, float16 | Pixel 6, весь конвейер: 2.94 мс CPU / 7.41 мс GPU; Pixel 2 (1 ядро, XNNPACK): ~275 FPS | MediaPipe Tasks — Android, iOS, Web, Python; **Windows в списке нет**. Под Windows — только через стороннюю конвертацию в ONNX/TFLite |
| **ML Kit Face Detection** (`google_mlkit_face_detection` 0.15.1) | Плагин — MIT (неофициальный, Google его не сопровождает) | Проприетарная модель Google, условия Google APIs | Разрешено по условиям Google, но **распознавания нет**: «does not recognize people» | — | — | Работает на устройстве | **Только Android (minSdk 21) и iOS (15.5+)**. Windows и Web не поддерживаются |
| **SCRFD** (InsightFace; детектор в buffalo_*) | MIT | «non-commercial research purposes only» | **Нет** без договора | — | buffalo_sc целиком (детектор и MBF) — 16 МБ | — | Через ONNX Runtime |

Вывод по детекции: для Windows с коммерческой лицензией подходит **YuNet**. BlazeFace допустим только на Android/iOS и с оговоркой о назначении модели. ML Kit годится только как вспомогательный детектор на мобильных платформах.

Источники: [OpenCV Zoo / YuNet](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet); [бенчмарк OpenCV Zoo](https://github.com/opencv/opencv_zoo/blob/main/benchmark/README.md); [MediaPipe Face Detector](https://developers.google.com/edge/mediapipe/solutions/vision/face_detector); [модельная карточка BlazeFace short-range (PDF)](https://storage.googleapis.com/mediapipe-assets/MediaPipe%20BlazeFace%20Model%20Card%20(Short%20Range).pdf); [ML Kit Face Detection](https://developers.google.com/ml-kit/vision/face-detection); [google_mlkit_face_detection](https://pub.dev/packages/google_mlkit_face_detection); [WIDER FACE на HF](https://huggingface.co/datasets/CUHK-CSE/wider_face); [Luxonis YuNet](https://models.luxonis.com/luxonis/yunet/5d635f3c-45c0-41d2-8800-7ca3681b1915); [InsightFace model_zoo](https://github.com/deepinsight/insightface/tree/master/model_zoo).

---

## 2. Выравнивание и эмбеддинг (распознавание)

Выравнивание: YuNet выдаёт 5 точек (глаза, нос, углы рта). По ним делается аффинное выравнивание в кроп 112×112. В OpenCV это `FaceRecognizerSF.alignCrop`, в `opencv_dart` класс `FaceRecognizerSF` есть («DNN-based face recognizer»). На стеке ONNX выравнивание пишется вручную: аффинное преобразование через `opencv_dart` или на Dart.

| Модель | Лицензия кода | Лицензия весов | Коммерческое использование | Набор для обучения | Точность (LFW и др.) | Размер / сложность | Скорость CPU |
|---|---|---|---|---|---|---|---|
| **SFace** (OpenCV Zoo `face_recognition_sface_2021dec.onnx`, есть int8 и int8bq) | Apache-2.0 | Apache-2.0 («All files in this directory are licensed under Apache 2.0 License») | **Да**, по лицензии файлов. Какой набор использован для весов Zoo, страница не сообщает. Статья SFace упоминает CASIA-WebFace, VGGFace2, MS-Celeb-1M — [НЕЯСНО] | Не указан для весов Zoo | 0.9940 (fp32), 0.9942 (block-quant), 0.9932 (int8). Набор в таблице не назван; порог OpenCV для LFW: cosine 0.363, L2 1.128 | 36.9 МБ [ВТОРИЧНЫЙ: пересказ туториала OpenCV] | i7-12700K: 5.09 мс fp32 / 6.50 мс int8; Raspberry Pi 4B: 68.82 / 87.42 мс; RK3588: 28.94 / 37.46 мс |
| **ArcFace / InsightFace** (buffalo_l: ResNet50@WebFace600K; buffalo_s/sc: MobileFaceNet@WebFace600K; antelopev2: ResNet100@Glint360K) | MIT («no limitation for both academic and commercial usage») | **«ALL models are available for non-commercial research purposes only»**; по buffalo_l — «contact recognition-oss-pack@insightface.ai for licensing» | **Нет** без договора | WebFace600K, Glint360K | buffalo_l: LFW 99.83, IJB-C(E4) 97.25; buffalo_s/sc: LFW 99.70, CFP-FP 98.00, AgeDB-30 96.58, IJB-C 95.02 | buffalo_l 326 МБ, buffalo_s 159 МБ, buffalo_sc 16 МБ (пакеты целиком) | Не публикуется |
| **MobileFaceNet** (foamliu/MobileFaceNet; та же модель в Qualcomm AI Hub) | Apache-2.0 | Qualcomm AI Hub указывает Apache-2.0 | **[НЕЯСНО]**: лицензия разрешает, но обучена на «очищенном» MS-Celeb-1M. Microsoft отозвала этот набор в 2019 г.; его исходные условия — только некоммерческие исследования | MS-Celeb-1M (3.8 млн изображений, 85 тыс. личностей) | LFW 99.48 % (в статье 99.55 %) | ~1 млн параметров, 4 МБ (float), эмбеддинг 128, вход 112×112 | AI Hub не даёт замеров для мобильных чипов («Not supported») |
| **EdgeFace** (Idiap; XXS / XS / S / Base) | BSD-3-Clause (файл LICENSE в github.com/otroshi/edgeface) | Модельные карточки Idiap на HF: **CC-BY-NC-SA-4.0**. Репозиторий GitLab Idiap: MIT. Демо на HF: BSD-3-Clause | **[НЕЯСНО]** — источники противоречат друг другу; по HF-карточкам «NC», то есть нет | WebFace260M (подвыборки 12M и 4M); условия набора не найдены [НЕЯСНО] | XXS: LFW 99.57, CFP-FP 93.63, AgeDB-30 94.92; XS: LFW 99.73; Base: LFW 99.83 | XXS 1.24 млн параметров / 94.7 MFLOPs; XS 1.77 млн / 154 MFLOPs; Base 18.2 млн / 1399 MFLOPs | Не публикуется |
| **FaceNet** (davidsandberg/facenet, Inception-ResNet-v1) | MIT | Не указана; в README только просьба «give proper credit to those providing the training dataset» | **[НЕЯСНО]** | CASIA-WebFace (LFW 99.05 %) / VGGFace2 (LFW 99.65 %). Условия VGGFace2 на официальном сайте ведут на отдельный «Terms of Use» и требуют регистрации — не проверено | LFW 0.9905 / 0.9965 | Не указан | Последнее обновление репозитория — 2018-04 |
| **AdaFace** (mk-minchul/AdaFace) | MIT | Не указана | **[НЕЯСНО]** (веса на CASIA-WebFace, VGGFace2, WebFace4M/12M, MS1MV2/V3) | см. слева | — | R18…R100 | — |

Почему лицензия весов важнее лицензии кода. Обзор наборов данных для обучения (Princeton, arXiv 2108.02922 и par.nsf.gov) отмечает три вещи: MS-Celeb-1M отозван, но продолжает распространяться; модели, обученные на наборах с некоммерческими условиями, широко используются в продуктах; при этом юридически вопрос о переходе условий набора на веса **не решён**. Для проекта это риск. Его снимает только письменное заключение юриста или коммерческая лицензия.

Источники: [OpenCV Zoo / SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface); [SFace (статья, репозиторий)](https://github.com/zhongyy/SFace); [InsightFace — лицензия](https://github.com/deepinsight/insightface); [InsightFace model_zoo](https://github.com/deepinsight/insightface/tree/master/model_zoo); [foamliu/MobileFaceNet](https://github.com/foamliu/MobileFaceNet); [Qualcomm AI Hub — MobileFaceNet](https://aihub.qualcomm.com/mobile/models/mobile_facenet); [EdgeFace — GitHub](https://github.com/otroshi/edgeface) и [LICENSE](https://raw.githubusercontent.com/otroshi/edgeface/main/LICENSE); [EdgeFace-XXS — HF](https://huggingface.co/Idiap/EdgeFace-XXS); [EdgeFace — GitLab Idiap](https://gitlab.idiap.ch/bob/bob.paper.tbiom2023_edgeface/-/blob/master/LICENSE); [davidsandberg/facenet](https://github.com/davidsandberg/facenet); [AdaFace](https://github.com/mk-minchul/AdaFace); [отзыв MS-Celeb-1M и лицензии наборов (arXiv 2108.02922)](https://par.nsf.gov/servlets/purl/10316366); [лицензии наборов ML (arXiv 2303.13735)](https://arxiv.org/pdf/2303.13735); [документация OpenCV DNN face](https://docs.opencv.org/4.x/d0/dd4/tutorial_dnn_face.html) (страница вернула 403, данные взяты из поисковой выдачи).

---

## 3. Движок вывода во Flutter

| Пакет | Версия / дата | Лицензия | Android | iOS | Windows | Примечания |
|---|---|---|---|---|---|---|
| **`opencv_dart`** (dartcv4) | 2.2.2, ≈ 2026-08 | Apache-2.0 | arm64-v8a, armeabi-v7a, x86_64 | arm64 (+ симулятор) | x64 | Нужен Dart ≥ 3.10 / Flutter ≥ 3.38 (native-assets hooks); **совместим с проектом**. Есть `FaceDetectorYN`, `FaceRecognizerSF` (и async-варианты), `VideoCapture`. Модули `dnn`, `objdetect`, `videoio` по умолчанию **выключены**, включаются через `hooks: user_defines: dartcv4: include_modules`. FFmpeg в dartcv ≥ 2.2.0 убран; бэкенд `VideoCapture` на Windows (MSMF/DSHOW) в документации не описан — [НЕЯСНО], нужен прототип. Документация пакета не завершена |
| **`flutter_onnxruntime`** | 1.9.0, ≈ 2026-10-06; Dart ≥ 3.7 | MIT | ORT 1.28.0 | ORT 1.28.0, iOS ≥ 16, статическая линковка | ORT 1.28.3, **скачивается при сборке** | Также Linux, macOS, Web. На iOS/macOS нет input/output info, FP16 на Windows только в планах. Android — правило ProGuard `ai.onnxruntime.**`. Скачивание при сборке означает, что CI-сборке Windows нужен интернет или кэш |
| `onnxruntime` (gtbluesky) | 1.4.1, ≈ 2 года назад | MIT | да | да | да | Не обновлялся около 2 лет; версия ORT на странице не указана. Для нового кода не рекомендуется |
| **`tflite_flutter`** | 0.12.1, ≈ 12 месяцев назад | Apache-2.0 | да (NNAPI, GPU) | да (Metal, CoreML) | да, но **`libtensorflowlite_c-win.dll` нужно собрать вручную** и подключить в `windows/CMakeLists.txt` | На десктопе — делегат XNNPack. Для YuNet/SFace потребуется конвертация ONNX→TFLite |
| MediaPipe Tasks | — | Apache-2.0 | да | да | **нет** | Официального Flutter-пакета Google нет |
| Собственный FFI к ONNX Runtime C API | — | ORT — MIT | — | — | — | Максимум контроля, но отдельная поддержка трёх нативных сборок. Имеет смысл, только если готовые пакеты не пройдут прототип |

Вывод: для стека A достаточно одного `opencv_dart`: детекция, выравнивание и эмбеддинг встроены в OpenCV, и пакет совместим с Flutter 3.38.7. Для стека B нужен `flutter_onnxruntime` и `opencv_dart` (или ручная реализация) для аффинного выравнивания.

Источники: [opencv_dart](https://pub.dev/packages/opencv_dart), [версии](https://pub.dev/packages/opencv_dart/versions), [документация](https://pub.dev/documentation/opencv_dart/latest/); [dartcv4 API](https://pub.dev/documentation/dartcv4/latest/dartcv); [flutter_onnxruntime](https://pub.dev/packages/flutter_onnxruntime), [версии](https://pub.dev/packages/flutter_onnxruntime/versions); [onnxruntime](https://pub.dev/packages/onnxruntime), [версии](https://pub.dev/packages/onnxruntime/versions); [tflite_flutter](https://pub.dev/packages/tflite_flutter).

---

## 4. Камера во Flutter

| Пакет | Версия / дата | Мин. Dart | Платформы | Поток кадров в Dart | Ограничения |
|---|---|---|---|---|---|
| `camera` (federated) | 0.12.1, ≈ 2026-09-03 | не указан | Android (SDK 24+), iOS (13.0+), Web (`camera_web`) | Заявлено «streaming image buffers to Dart» (`startImageStream`). Таблицы по платформам на странице нет | Формат кадров по платформам на странице не указан. По практике — YUV420/NV21 на Android и BGRA8888 на iOS [НЕЯСНО — проверить на прототипе] |
| **`camera_windows`** | 0.3.0+1 (≈ 2026-10-22, Dart ≥ 3.11); **0.2.6+5** (≈ 2026-08-28, Dart ≥ 3.10 — последняя версия, совместимая с Flutter 3.38.7) | см. слева | Windows | **Нет.** «Support for image streaming is not yet implemented». В 0.2.5 поток добавили, в 0.2.6 откатили: «implementation was incorrect and never exposed» | Нет ориентации, паузы записи, экспозиции и фокуса, вспышки; плагин «under development». Доступны только превью, `takePicture` и запись видео |
| **`camera_desktop`** (hugo.ml, verified) | 2.0.0, ≈ 2026-09-25 | **3.11** (все последние версии) | Windows (Media Foundation), Linux, macOS | **Да**, на Windows заявлен; кадры на Windows не зеркалятся | Реализует `camera_platform_interface` (работает с `CameraController`, `camera ^0.11.0`). Нет вспышки, точек экспозиции и фокуса, зума > 1.0, смены ориентации, паузы записи. Параметры FPS и битрейта меняются только пересозданием контроллера. **Несовместим с Flutter 3.38.7** — нужен Flutter с Dart 3.11 |
| `opencv_dart` `VideoCapture` | 2.2.2 | 3.10 | Windows x64 и др. | Технически да (захват в `Mat`) | Модуль `videoio` по умолчанию выключен; бэкенд захвата на Windows после удаления FFmpeg не документирован — [НЕЯСНО]. Превью придётся рисовать самим (`Mat` → изображение) |
| `mobile_scanner` (уже в проекте) | ^7.4.2 | — | Android, iOS | Для произвольной обработки кадров не предназначен | Только сканер штрихкодов |

Варианты для Windows — от наименьшего изменения стека к наибольшему:
1. `camera_windows` 0.2.6+5 + серия `takePicture()` (кадр через файл). Медленно; для регистрации по 3–5 снимкам приемлемо, для активного liveness (моргание, поворот) нет. Скорость нужно мерить — [НЕЯСНО].
2. `opencv_dart` `VideoCapture` (включить `videoio`). Нужен прототип: работает ли захват с USB-камеры без FFmpeg.
3. Обновить Flutter до версии с Dart ≥ 3.11 и взять `camera_desktop` 2.0.0. Это отступление от утверждённого стека (R3/D-04): ТЗ требует отдельного решения и регресса всего приложения.
4. Собственный platform channel на Media Foundation (C++). Максимум контроля, но больше всего работы и поддержки.

Дополнительно об оборудовании: у Regula liveness требует камеру не ниже «HD 1024x720». Камеры касс заказчика нам неизвестны, это открытый вопрос.

Источники: [camera](https://pub.dev/packages/camera); [camera_windows](https://pub.dev/packages/camera_windows), [changelog](https://pub.dev/packages/camera_windows/changelog), [версии](https://pub.dev/packages/camera_windows/versions); [camera_desktop](https://pub.dev/packages/camera_desktop), [версии](https://pub.dev/packages/camera_desktop/versions); [opencv_dart](https://pub.dev/documentation/opencv_dart/latest/); [Regula Face SDK — введение](https://docs.regulaforensics.com/develop/face-sdk/overview/introduction/).

---

## 5. Готовые коммерческие SDK (офлайн-распознавание и liveness)

| SDK | Платформы | Flutter | Офлайн-распознавание | Liveness / PAD | Цена / модель лицензирования | Статус |
|---|---|---|---|---|---|---|
| **Luxand FaceSDK** 9.0.1 | Windows 7–11 и Server 2008 R2–2022; Linux; macOS 10.13+; iOS 15+; Android 5.0+ (arm64, armv7, x86, x86_64); WebAssembly | Flutter заявлен как среда разработки. Официально есть только пример `Liveness-Flutter.zip`, платформы не указаны [НЕЯСНО]; на pub.dev — неофициальный `luxand_facesdk` 0.0.1 без описания | Да: «No internet connection required», статическая линковка | Пассивный anti-spoofing; на странице «iBeta Level 1&2 Certified». Работает ли liveness офлайн, страница прямо не говорит [НЕЯСНО]. Функции веб-камеры — только на Windows и Linux | На сайте — пробный период и запрос цены, ссылка «Cancel FaceSDK Subscription» (похоже на подписку). $0.02 за установку — по Fitgap [ВТОРИЧНЫЙ, не проверено] | [ПОДТВЕРЖДЕНО: luxand.com] + [ВТОРИЧНЫЙ: цена] |
| **Neurotechnology VeriLook** | Windows, Linux, macOS, iOS, Android | Нет: примеры на C/C++, C#, VB.NET, Java, Python. Нужен FFI или platform channel | Да (SDK на устройстве) | Liveness заявлен как соответствующий ISO/IEC 30107 (на странице опечатка «30103-7»); есть компонент PAD | У реселлера Fulcrum Biometrics: Standard SDK $366, Extended SDK $928, Face Verification SDK $1 501 [ВТОРИЧНЫЙ]. Лицензии на развёртывание — отдельно, у производителя | [ПОДТВЕРЖДЕНО: neurotechnology.com] + [ВТОРИЧНЫЙ: цены] |
| **Regula Face SDK** | Мобильные: iOS, Android, Flutter, JS, .NET MAUI. Windows и Linux — только Web Service (сервер, контейнеры) | `flutter_face_api` 8.4.1655 (≈ 2026-10-08, verified mobile.regulaforensics.com, обёртка под MIT): **только Android 7.0+ и iOS 15+** | Сравнение 1:1 — «on the client side without using a web server». Для 1:N клиентский режим не описан | Модуль liveness требует дополнительных backend-компонентов (Milvus, хранилище, БД) | По запросу | [ПОДТВЕРЖДЕНО: docs.regulaforensics.com, pub.dev] |
| **FaceTec** | Демо: iOS, Android, Web. Windows на странице цен не упомянута | Официального плагина нет; есть неофициальный демо-плагин (Android/iOS) | Нет: «must run the FaceTec software on their servers» (на своих серверах заказчика) | 3D Liveness | Помесячно за проверки или пользователей, **с минимальным ежемесячным платежом**; без минимума — через партнёров | [ПОДТВЕРЖДЕНО: facetec.com/pricing] |
| **3DiVi Face SDK** | Плагин `face_sdk_3divi` 1.6.0 (≈ 16 месяцев назад): Android, iOS | **AGPL-3.0**: для закрытого коммерческого приложения нужна коммерческая лицензия. В пакете только демо-лицензия с ограничением по времени | Детекция, точки, сравнение 1:1 | Liveness — в отдельном «Advanced SDK» | По запросу | [ПОДТВЕРЖДЕНО: pub.dev] |
| **KBY-AI** | Flutter-SDK: Android, iOS. Для Windows отдельные продукты, серверного типа | Да, только мобильные платформы | Да (мобильные) | Да | Лицензия на application ID; цены не опубликованы | [ВТОРИЧНЫЙ: github.com/kby-ai] |
| **Paravision** | Android/iOS SDK; хост Linux/Windows (C++/Python) | Нет | Да (мобильный SDK: 1:1 и 1:N) | 2D PAD iBeta L1/L2 (документ за январь 2024); новый liveness в основном серверный (Docker) | По запросу; документам 2022–2024 гг. | [ВТОРИЧНЫЙ: даташиты paravision.ai] |
| **FacePlugin** | Заявлены Windows, Mac, Linux, Android, iPhone | Официальный Flutter-SDK не найден | Да, «fully on premise» | «3D passive liveness» | Бессрочная лицензия $3 000–15 000 [ВТОРИЧНЫЙ: AlternativeTo] | [ВТОРИЧНЫЙ] |
| `facekit` (Innoartive Labs) | Android, iOS, Linux, macOS, Web, Windows; MIT | Чистый Dart | Да | **Нет** (в планах) | Бесплатно | Не нейросеть: ручные признаки (LBP, HOG), метрик точности нет. Публикатор не верифицирован. **Не годится** для входа в кассу |

Вывод: на трёх целевых платформах офлайн-распознавание с заявленным сертифицированным liveness есть только у **Luxand** (сертификация iBeta заявлена на сайте) и **Neurotechnology** (соответствие ISO/IEC 30107 заявлено самим производителем). Оба потребуют нативной обвязки для Flutter. Цены нужно запросить официально.

Источники: [Luxand FaceSDK](https://www.luxand.com/facesdk/), [требования](https://luxand.com/facesdk/documentation/requirements.php), [Flutter](https://luxand.com/facesdk/documentation/usingflutter.php), [luxand_facesdk](https://pub.dev/packages/luxand_facesdk), [Fitgap — Luxand](https://us.fitgap.com/products/luxand-facesdk); [VeriLook](https://www.neurotechnology.com/verilook.html), [Fulcrum — Standard](https://store.fulcrumbiometrics.com/products/verilook-standard-sdk), [Extended](https://store.fulcrumbiometrics.com/products/verilook-extended-sdk), [Face Verification](https://store.fulcrumbiometrics.com/products/face-verification-sdk); [Regula — введение](https://docs.regulaforensics.com/develop/face-sdk/overview/introduction/), [архитектура](https://docs.regulaforensics.com/develop/face-sdk/overview/architecture), [flutter_face_api](https://pub.dev/packages/flutter_face_api); [FaceTec — цены](https://www.facetec.com/pricing), [FaceTec Flutter demo](https://pub.dev/documentation/facetec_flutter_plugin_demo/latest/); [face_sdk_3divi](https://pub.dev/packages/face_sdk_3divi); [KBY-AI](https://github.com/kby-ai); [Paravision — мобильные SDK](https://www.paravision.ai/resource/paravision-face-recognition-and-liveness-sdks-for-mobile-platforms/), [liveness, 01.2024](https://www.paravision.ai/wp-content/uploads/2022/10/paravision_datasheet_liveness_january_2024.pdf); [FacePlugin — AlternativeTo](https://alternativeto.net/software/face-recognition-sdk-faceplugin/about); [facekit](https://pub.dev/packages/facekit); [Silent-Face-Anti-Spoofing](https://github.com/minivision-ai/Silent-Face-Anti-Spoofing).

### 5.1. Открытый liveness

- **MiniFASNet V1/V2** (minivision-ai/Silent-Face-Anti-Spoofing): Apache-2.0. Отдельной лицензии на веса нет, действует лицензия репозитория. Вход 80×80, 0.08 GFLOPs, ~0.4 млн параметров. По данным автора: TPR 97.8 % при FPR 1e-5, 19–25 мс на мобильных SoC. Последнее обновление — 2020-07-30; открыта только «APK-модель», более точная модель закрыта. Независимой сертификации нет.
- Вывод: сам по себе открытый стек не даёт подтверждённой защиты от фото и видео. Варианты — активные проверки (моргание, поворот головы; на Windows для них нужен поток кадров, см. §4) или коммерческий PAD. Подробно — в части R9 о подделках.

---

## 6. Рекомендуемые стеки

### Стек A — `opencv_dart` + YuNet + SFace (рекомендуется для прототипа и как открытый базовый вариант)
- **Состав:** `opencv_dart` 2.2.2 (Apache-2.0) с модулями `dnn` и `objdetect`; YuNet 2023mar (MIT, ≈ 0.3 МБ); SFace 2021dec (Apache-2.0, ≈ 37 МБ, или int8). Камера: `camera` на Android/iOS; на Windows — вариант 1 или 2 из §4 по итогам прототипа.
- **Почему:** только здесь лицензии кода и весов явно разрешают коммерческое использование. Один пакет на все три платформы, совместим с Flutter 3.38.7 без обновления. Опубликованы бенчмарки CPU: детекция < 1 мс, эмбеддинг ≈ 5 мс на i7-12700K; на слабом ARM — десятки мс. В OpenCV есть готовые `alignCrop`, `feature`, `match` и пороги для LFW.
- **Минусы:** точность по таблице Zoo 99.40 % — ниже EdgeFace, ArcFace, MobileFaceNet (99.5–99.8 %). Набор, на котором обучены веса Zoo, не указан — [НЕЯСНО]. Liveness нет. Кадры на Windows — открытый вопрос.

### Стек B — `flutter_onnxruntime` + YuNet + сменная модель эмбеддинга
- **Состав:** `flutter_onnxruntime` 1.9.0 (MIT, ORT 1.28.x) на всех трёх платформах; YuNet (ONNX); эмбеддинг сначала SFace (ONNX). Замена на EdgeFace-XS или XXS (лучше точность при 1.2–1.8 млн параметров) или MobileFaceNet — **только** после письменного подтверждения лицензии (EdgeFace: противоречие BSD-3-Clause и CC-BY-NC-SA-4.0; MobileFaceNet: MS-Celeb-1M).
- **Почему:** модель отделена от движка, её можно заменить без смены обвязки. ORT активно обновляется. Можно подключить MiniFASNet (ONNX) для пассивного liveness.
- **Минусы:** выравнивание и пре- и постобработку надо писать самим. ORT для Windows скачивается при сборке. Те же вопросы с камерой Windows и сертифицированным liveness.

### Стек C — коммерческий SDK (Luxand FaceSDK или Neurotechnology VeriLook)
- **Состав:** нативный SDK; на Windows — FFI (C API), на Android/iOS — platform channel или FFI. У Luxand функции веб-камеры есть только на Windows и Linux, поэтому захват на Windows можно взять из SDK, а не из Flutter.
- **Почему:** только у этих SDK заявлены офлайн-распознавание и PAD с сертификацией или соответствием ISO/IEC 30107-3 на всех трёх платформах. Юридическая чистота весов закрывается договором.
- **Минусы:** цены непрозрачны (по запросу; у реселлера VeriLook от $366 за SDK, лицензии на развёртывание отдельно). Flutter-обвязки нет. Зависимость от поставщика. Сертификация liveness проверена только по заявлениям производителей.

**Не рекомендуется:** веса InsightFace (некоммерческие); MediaPipe и ML Kit как основа (нет Windows, нет распознавания; карточка BlazeFace исключает распознавание личности); `facekit` (нет нейросети, нет метрик); FaceTec, Regula, 3DiVi, KBY-AI для Windows-касс (в Flutter только мобильные платформы или серверный liveness).

---

## 7. Открытые вопросы (для решения заказчика и других частей R9)

1. Допустимо ли обновить Flutter до версии с Dart ≥ 3.11 ради `camera_desktop`, то есть отступить от утверждённого стека R3/D-04? Если нет — нужен прототип захвата кадров на Windows через `opencv_dart VideoCapture` или `takePicture`.
2. Какие камеры стоят на кассах (модель, разрешение, есть ли ИК-камера для Windows Hello)? От этого зависят liveness и выбор стека.
3. Какой уровень защиты от подделки нужен: достаточно ли активного liveness без сертификации или требуется PAD с iBeta / ISO/IEC 30107-3 (тогда стек C)?
4. Какие пороги ошибок нужны (FAR/FRR) и сколько людей в базе: только 1:1 по номеру телефона или 1:N без ввода номера?
5. Нужны официальные коммерческие предложения Luxand и Neurotechnology: лицензия на кассу или установку, Flutter-обвязка, офлайн-liveness на Windows.
6. Какие условия у весов SFace из OpenCV Zoo (набор для обучения)? Как EdgeFace лицензирует веса — нужен письменный ответ Idiap? Каковы условия WIDER FACE для весов YuNet?
7. Где хранится шаблон лица: на устройстве или на сервере, — и как это сочетается с Цифровым кодексом КР (биометрия — специальная категория, R6 §0 п.6). Это вопрос юридической части R9.

## 8. Список источников (все — дата обращения 2026-10-26)

- OpenCV Zoo: https://github.com/opencv/opencv_zoo ; YuNet: https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet ; SFace: https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface ; бенчмарк: https://github.com/opencv/opencv_zoo/blob/main/benchmark/README.md
- Туториал OpenCV DNN face (403, данные по выдаче поиска): https://docs.opencv.org/4.x/d0/dd4/tutorial_dnn_face.html
- MediaPipe Face Detector: https://developers.google.com/edge/mediapipe/solutions/vision/face_detector ; карточка BlazeFace: https://storage.googleapis.com/mediapipe-assets/MediaPipe%20BlazeFace%20Model%20Card%20(Short%20Range).pdf
- ML Kit: https://developers.google.com/ml-kit/vision/face-detection ; https://pub.dev/packages/google_mlkit_face_detection
- InsightFace: https://github.com/deepinsight/insightface ; https://github.com/deepinsight/insightface/tree/master/model_zoo
- EdgeFace: https://github.com/otroshi/edgeface ; https://raw.githubusercontent.com/otroshi/edgeface/main/LICENSE ; https://huggingface.co/Idiap/EdgeFace-XXS ; https://gitlab.idiap.ch/bob/bob.paper.tbiom2023_edgeface/-/blob/master/LICENSE
- MobileFaceNet: https://github.com/foamliu/MobileFaceNet ; https://aihub.qualcomm.com/mobile/models/mobile_facenet
- FaceNet: https://github.com/davidsandberg/facenet ; AdaFace: https://github.com/mk-minchul/AdaFace ; SFace (статья): https://github.com/zhongyy/SFace
- Наборы данных: https://huggingface.co/datasets/CUHK-CSE/wider_face ; https://par.nsf.gov/servlets/purl/10316366 ; https://arxiv.org/pdf/2303.13735 ; https://arxiv.org/pdf/1710.08092
- Silent-Face-Anti-Spoofing: https://github.com/minivision-ai/Silent-Face-Anti-Spoofing
- pub.dev: https://pub.dev/packages/opencv_dart ; https://pub.dev/documentation/opencv_dart/latest/ ; https://pub.dev/documentation/dartcv4/latest/dartcv ; https://pub.dev/packages/flutter_onnxruntime ; https://pub.dev/packages/onnxruntime ; https://pub.dev/packages/tflite_flutter ; https://pub.dev/packages/camera ; https://pub.dev/packages/camera_windows ; https://pub.dev/packages/camera_windows/changelog ; https://pub.dev/packages/camera_desktop ; https://pub.dev/packages/flutter_face_api ; https://pub.dev/packages/face_sdk_3divi ; https://pub.dev/packages/facekit ; https://pub.dev/packages/luxand_facesdk
- Luxand: https://www.luxand.com/facesdk/ ; https://luxand.com/facesdk/documentation/requirements.php ; https://luxand.com/facesdk/documentation/usingflutter.php ; https://us.fitgap.com/products/luxand-facesdk
- Neurotechnology: https://www.neurotechnology.com/verilook.html ; https://store.fulcrumbiometrics.com/products/verilook-standard-sdk ; https://store.fulcrumbiometrics.com/products/verilook-extended-sdk ; https://store.fulcrumbiometrics.com/products/face-verification-sdk
- Regula: https://docs.regulaforensics.com/develop/face-sdk/overview/introduction/ ; https://docs.regulaforensics.com/develop/face-sdk/overview/architecture
- FaceTec: https://www.facetec.com/pricing ; https://pub.dev/documentation/facetec_flutter_plugin_demo/latest/
- Paravision: https://www.paravision.ai/resource/paravision-face-recognition-and-liveness-sdks-for-mobile-platforms/ ; https://www.paravision.ai/wp-content/uploads/2022/10/paravision_datasheet_liveness_january_2024.pdf
- KBY-AI: https://github.com/kby-ai ; FacePlugin: https://alternativeto.net/software/face-recognition-sdk-faceplugin/about
