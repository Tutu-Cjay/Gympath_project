# GymPath — Бүтээгдэхүүний санаа ба хэрэгжүүлэлтийн төлөвлөгөө

- **Төлөв:** Концепц / хэрэгжүүлэлтийн өмнөх баримт бичиг
- **Эхний дасгалууд:** Cable machine-ийн 6 дасгал (анх squat гэж төлөвлөсөн, 12-р хэсгийг үз)
- **Платформ:** Android (Flutter), цаашид 3D runtime болон backend
- **Зорилго:** Дасгалжуулагчийн бодит дасгалын бичлэгийг хөдөлгөөний өгөгдөл болгон хувиргаж, хэрэглэгчид 3D анатомийн загвараар ойлгомжтой заавар өгөх

## 1. Бүтээгдэхүүний үндсэн санаа

GymPath нь дасгалжуулагчийн заасан хөдөлгөөнийг хэрэглэгчид зөв техникээр давтахад туслах фитнес платформ байна. Дасгалжуулагч утсаараа дасгалаа бичиж платформд оруулна. Систем бичлэгээс хүний pose/joint landmark-уудыг тооцоолж, хөдөлгөөний дарааллыг ерөнхий 3D хүний араг яс/биеийн rig дээр шилжүүлнэ. Үүссэн хөдөлгөөнийг 3D анатомийн загварт харуулж, тухайн дасгалын үед ажиллах булчингийн бүлгүүдийг үе шаттай тодруулна.

Хэрэглэгч дасгалын зааврыг үзэж, 3D хөдөлгөөнийг өөрийн хурдаар тоглуулж/зогсоож, давталт болон хөдөлгөөний үе шатыг ойлгоно. Дараагийн шатанд хэрэглэгч өөрийн камераар бичлэг хийж, дасгалжуулагчийн жишээ хөдөлгөөнтэй харьцуулан техникээ шалгуулах боломжтой болно.

## 2. Хэрэглэгчийн үндсэн урсгал

### 2.1 Дасгалжуулагчийн урсгал
1. Дасгалжуулагч GymPath-д нэвтэрнэ.
2. Дасгалын нэр, тайлбар, түвшин, анхаарах зүйлсийг оруулна.
3. Утасны камераар дасгалыг нэг эсвэл боломжтой бол олон өнцгөөс бичнэ.
4. Бичлэгийг upload хийнэ.
5. Backend бичлэгээс pose landmark-ууд болон хөдөлгөөний үе шатуудыг гаргана.
6. Систем хөдөлгөөнийг стандарт 3D rig-д retarget хийж preview үүсгэнэ.
7. Дасгалжуулагч хөдөлгөөнийг шалгаж, шаардлагатай бол засвар/дахин боловсруулалт хийгээд нийтэлнэ.

### 2.2 Хэрэглэгчийн урсгал
1. Хэрэглэгч дасгалын feed эсвэл хайлтаас дасгал сонгоно.
2. Дасгалын тайлбар, зөв техник, аюулгүй ажиллагааны cue-г уншина.
3. 3D анатомийн дүрслэлээр хөдөлгөөнийг харна.
4. Play/pause, timeline, playback speed, урд/хажуугийн харагдац зэргийг ашиглана.
5. Идэвхтэй булчингийн бүлгүүд болон хөдөлгөөний үе шатыг харна.
6. Дараагийн хувилбарт өөрийн бичлэгийг оруулж, reference хөдөлгөөнтэй харьцуулна.

## 3. Гол боломжууд

### MVP-д заавал багтах
- Дасгалын жагсаалт болон дасгалын дэлгэрэнгүй хуудас
- Эхний жишээ дасгал: squat
- 3D хүний rig дээр тоглох хөдөлгөөний animation
- Play / pause, playback speed, timeline scrub
- Урд / хажуу / эргүүлж харах camera control
- Булчингийн бүлгийг өнгөөр ялгаж тодруулах
- Дасгалын үе шаттай уялдсан богино coaching cue
- Дасгалжуулагчийн контент preview болон publish хийх энгийн урсгал

### Дараагийн хувилбар
- Дасгалжуулагчийн видео upload
- Видеоноос pose estimation хийх автомат pipeline
- Pose-оос 3D rig рүү retarget хийх
- Rep detection болон хөдөлгөөний phase segmentation
- Хэрэглэгчийн камераар бодит цагийн pose tracking
- Reference ба хэрэглэгчийн хөдөлгөөнийг зэрэгцүүлэн replay хийх
- GymPath wearable / ESP32 төхөөрөмжийн IMU өгөгдөлтэй холбох

## 4. Системийн санал болгож буй архитектур

### Android клиент — Flutter
- Нэвтрэлт, профайл, дасгалын feed, хайлт
- Дасгалын дэлгэрэнгүй болон coaching UI
- Видео upload болон playback
- Wearable төхөөрөмжтэй BLE холболтын UI
- 3D модулийг нээх, backend API-тай харилцах

### 3D хөдөлгүүр — Unity (сонголт)
- Rigged human/anatomy model
- Animation playback болон retargeted motion
- Булчингийн бүлгийн material/highlight control
- Camera orbit, zoom, view presets
- Timeline болон хөдөлгөөний phase visualization

3D хөдөлгүүрийг сонгохдоо Flutter plugin-ийн тогтвортой байдал, Android build integration, GPU performance, memory footprint-ийг туршилтаар баталгаажуулна. Эхний прототипод Unity-г Flutter-тэй шууд нэгтгэх эсэхийг техникийн spike-аар шийднэ.

### Pose estimation ба боловсруулалтын backend
Python + MediaPipe Pose Landmarker нь эхний туршилтын сонголт байна.
- Видео decode болон frame sampling
- Pose landmark extraction
- Landmark smoothing / filtering
- Joint angle болон хөдөлгөөний feature тооцоолол
- Rep segmentation, phase labeling
- 3D rig-д зориулсан animation data export

Pose estimation нь булчингийн бодит идэвхжлийг хэмжихгүй. Булчингийн highlight нь дасгалын төрөл, үе шат, дасгалжуулагчийн баталгаажуулсан дүрэмд үндэслэсэн тайлбар байна.

### Backend ба өгөгдөл
Эхний production хувилбарт санал болгох бүрэлдэхүүн:
- API: FastAPI
- Database: PostgreSQL
- Видео болон animation asset: object storage
- Background processing: queue/worker
- Metadata: дасгал, дасгалжуулагч, бичлэг, pose result, animation version, muscle annotation

Эдгээр нь санал болгож буй сонголт бөгөөд бодит хэрэглээ, өртөг, багийн туршлагаар эцэслэн баталгаажуулна.

## 5. Видеоноос 3D animation үүсгэх pipeline

1. **Upload:** Дасгалжуулагчийн эх видео, камерын байрлал болон дасгалын metadata-г хадгална.
2. **Preprocess:** FPS, resolution, orientation-ийг нэг стандарт руу оруулна.
3. **Pose extraction:** Frame бүрийн landmark болон confidence утгыг гаргана.
4. **Filtering:** Jitter багасгаж, тасарсан landmark-уудыг боломжтой хүрээнд нөхнө.
5. **Biomechanical features:** Joint angle, velocity, range of motion зэрэг feature тооцно.
6. **Segmentation:** Эхлэх байрлал, eccentric, bottom, concentric, finish зэрэг phase болон repetition-ийг ялгана.
7. **Retargeting:** Landmark/холбоосын хөдөлгөөнийг стандарт 3D skeleton/rig-д хөрвүүлнэ.
8. **Muscle annotation:** Дасгал болон phase бүрт тохирох булчингийн бүлгийг annotation-аар тодорхойлно.
9. **Review:** Дасгалжуулагч animation preview-г шалгаж, зөвшөөрнө.
10. **Publish:** Баталгаажсан animation, тайлбар, metadata-г хэрэглэгчдэд нийтэлнэ.

Нэг камерын бичлэг нь гүн болон далдлагдсан мөчдийн мэдээллийг бүрэн өгдөггүй. Тиймээс эхний хувилбарт хөдөлгөөний ерөнхий хэлбэр, үе шат, хэмнэлийг харуулахад ашиглаж, нарийн 3D биомеханикийн хэмжилт гэж танилцуулахгүй.

## 6. Squat — эхний дасгалын жишиг

Squat нь эхний end-to-end туршилтын дасгал байна.

**Хөдөлгөөний үндсэн phase**
- Start / standing
- Descent (eccentric)
- Bottom position
- Ascent (concentric)
- Finish / standing

**Эхний muscle group annotation**
- Quadriceps
- Gluteus maximus
- Hamstrings
- Core stabilizers

Эдгээрийг тухайн phase-д тохируулан тодруулна. Энэ нь EMG эсвэл бодит булчингийн хүч хэмжилт биш, сургалтын зориулалттай анатомийн тайлбар юм.

**Coaching cue-ийн жишээ**
- Хөлийн ул газарт тогтвортой байлгах
- Өвдөгний чиглэлийг хөлийн өлмийтэй ойролцоо барих
- Нурууны байрлалыг хяналттай хадгалах
- Өөрийн хөдөлгөөний хүрээ, чадварт тохируулан доошлох

## 7. Хэрэглэгчийн өөрийн хөдөлгөөнийг шалгах боломж

Дараагийн шатанд хэрэглэгч камераа байрлуулж дасгал хийж буй бичлэгээ авна. Систем хэрэглэгчийн pose-г reference animation-тай харьцуулна.

Харьцуулах үзүүлэлтүүд:
- Хөдөлгөөний phase болон дараалал
- Rep count
- Tempo / phase duration
- Гол joint angle-ийн ойролцоо зөрүү
- Range of motion
- Тэнцвэр, symmetry-г зөвхөн тухайн камерын өнцөгт найдвартай хэмжигдэх хүрээнд

Нэг камерын pose estimation-ийн алдаа, occlusion, камерын өнцөг, хэрэглэгчийн биеийн пропорцын ялгааг харгалзана. Эхний хувилбарт оноог эмнэлзүйн эсвэл гэмтлээс хамгаалах баталгаатай үнэлгээ мэт үзүүлэхгүй.

## 8. GymPath wearable интеграц

Одоо байгаа ESP32 wearable-ийн боломжийг хадгалж, цаашид IMU өгөгдлийг дасгалын бичлэгтэй timestamp-аар синхрончлох боломжийг судална.
- BLE-ээр төхөөрөмжтэй холбогдох
- IMU sensor stream болон battery/device status авах
- Утасны цагтай timestamp alignment хийх
- Видео/pose timeline дээр sensor event харуулах
- QMI8658 зэрэг IMU-гийн өгөгдлийг pose estimation-ийн нэмэлт эх үүсвэр болгох

Wearable-ийн одоогийн firmware, BLE protocol, sensor calibration-ийг эхлээд repository-оос шалгаж байж интеграцийн шийдлийг тодорхойлно. Одоогийн ажиллаж буй функцуудыг эвдэхгүй байх нь гол шаардлага.

## 9. Хэрэгжүүлэлтийн үе шат

| Үе шат | Ажил | Гарах үр дүн |
|---|---|---|
| 0. Суурь судалгаа | Одоогийн Flutter app, backend, wearable кодыг аудитлах | Архитектур ба эрсдэлийн жагсаалт |
| 1. UI prototype | Squat exercise page, playback controls, feed | Ашиглаж болох Flutter prototype |
| 2. 3D proof of concept | Rigged model, squat animation, muscle highlight | Android дээр ажиллах 3D demo |
| 3. Offline pose pipeline | Видео → pose → phase → rig animation | Нэг видеоноос animation asset |
| 4. Coach workflow | Upload, preview, approve, publish | Дасгалжуулагчийн контентын урсгал |
| 5. User tracking | Камераар pose авах, reference-тай харьцуулах | Хэрэглэгчийн form feedback prototype |
| 6. Wearable integration | BLE/IMU өгөгдөл синхрончлох | Нэмэлт sensor feedback |
| 7. Production hardening | Performance, privacy, testing, monitoring | Туршилтын хэрэглээнд бэлэн хувилбар |

## 10. Хүлээн авах шалгуур

### 3D MVP
- Android төхөөрөмж дээр 3D загвар тогтвортой дүрслэгдэх
- Squat animation pause/play болон speed control-той байх
- Хэрэглэгч camera-г эргүүлж, zoom хийж чаддаг байх
- Сонгосон muscle group-ууд зөв харагдах
- Дасгалын phase болон cue animation-тай синхрон байх

### Pose pipeline MVP
- Нэг стандарт squat видеог боловсруулах
- Landmark confidence болон алдааны мэдээллийг хадгалах
- Rep болон үндсэн phase-уудыг гаргах
- Үүссэн animation-г дасгалжуулагч preview хийж батлах
- Боловсруулалтын үр дүнг дахин үүсгэх боломжтой version-той хадгалах

## 11. Эрсдэл ба анхаарах зүйл

- **Pose accuracy:** Камерын өнцөг, гэрэлтүүлэг, хувцас, occlusion нөлөөлнө.
- **3D retargeting:** 2D landmark-оос 3D хөдөлгөөн сэргээхэд ambiguity бий.
- **Anatomy asset:** Ашиглах 3D model болон animation asset-ийн лицензийг шалгах.
- **Performance:** Mobile GPU, memory, battery болон thermal throttling-ийг хэмжих.
- **Privacy:** Бичлэг нь хүний биометрийн шинжтэй мэдээлэл агуулж болзошгүй; consent, retention, deletion, access control шаардлагатай.
- **Safety:** Автомат feedback-ийг эмнэлгийн онош эсвэл гэмтлээс хамгаалах баталгаа мэт харуулахгүй.
- **Wearable compatibility:** Одоо байгаа ESP32 firmware болон BLE contract-ийг хадгалах.

## 12. Одоогийн prototype-ийн хүрээ

**Чиглэлийн өөрчлөлт (2026-11-17):** GymPath-ийн tracker нь cable machine-д зориулагдсан тул Movement Studio нь squat биш, апп-ын жагсаалтад байгаа 6 cable дасгалыг харуулна: Lat Pulldown, Seated Cable Row, Tricep Pushdown, Cable Bicep Curl, Cable Chest Fly, Face Pull. Дээрх 6-р хэсгийн squat-ийн жишиг нь түүхэн лавлагаа болж үлдэнэ.

Одоо хийгдсэн зүйл:

- **3D анатомийн загвар:** BodyParts3D-ийн бодит булчин, ясны хэлбэрүүд (булчин бүр тусдаа mesh). `tools/build_anatomy_model.py` нь тэдгээрийг энгийн араг ясанд холбож, дасгал бүрийн хөдөлгөөнийг оруулан `mobile/assets/models/anatomy_cable.glb` үүсгэнэ.
- **Арьстай дүр:** булчингийн дээр BodyParts3D-ийн арьсны давхарга хагас тунгалаг байдлаар бүрхэнэ (шорттой). Ажиллаж буй булчин арьсан доороос өөрийн хэлбэрээр тод харагдана. "SKIN" товчоор арьсыг унтрааж бүх булчинг харж болно.
- **Булчингийн тодруулга:** булчингийн бүлэг бүр загварт тусдаа material. Апп тухайн дасгалын гол булчинг ногооноор, туслах булчинг шараар, агшилтын хэмжээгээр тодруулна. Гадаргуу дээр гараар будсан зүйл байхгүй.
- **Апп:** `AnatomyStudioScreen` (model_viewer_plus) — дасгал сонгох, эргүүлэх/zoom, play/pause, хурд, timeline, булчинг тусад нь харах, phase бүрийн cue. Workout жагсаалтын мөр бүрээс шууд нээгдэнэ.
- **Дасгалын өгөгдөл:** `mobile/lib/models/cable_exercise.dart`.

Хязгаарлалт:

- Хөдөлгөөн нь гараар тодорхойлсон гарын чиглэлүүд; дасгалжуулагчийн видеоноос гаргасан pose өгөгдөл хараахан биш.
- Бүх дасгал зогсоо байрлалаар харагдана (суугаа байрлал, cable/бариул зураагүй).
- Тодруулга нь сургалтын зураглал; EMG эсвэл бодит булчингийн хүчний хэмжилт биш.

**Лиценз:** BodyParts3D, © The Database Center for Life Science, CC Attribution-Share Alike 2.1 Japan. Загварын файл нь мөн энэ лицензтэй (share-alike), апп дотор credit заавал харагдана. openGym-ээс код, зураг аваагүй (AGPL / зөвхөн openGym-д ашиглах эрхтэй медиа); зөвхөн санаа авна.

## 13. Дараагийн шууд хийх ажлууд

1. Repository-ийн одоогийн бүтэц, Flutter app болон wearable кодыг аудитлах.
2. 3D runtime-ийн жижиг technical spike хийх (Unity integration ба performance).
3. Лиценз нь зөвшөөрөгдсөн rigged human/anatomy asset сонгох.
4. Squat-ийн нэг reference видео дээр pose extraction турших.
5. Animation data format болон Flutter ↔ 3D runtime interface тодорхойлох.
6. Эхний 3D squat demo-г Android дээр ажиллуулах.

---

**Бүтээгдэхүүний зарчим:** Эхлээд нэг дасгал (squat)-ийг дасгалжуулагчийн видеоноос эхлээд хэрэглэгчийн 3D заавар хүртэл бүрэн урсгалаар ажиллуулна. Үүний дараа бусад дасгал, бодит цагийн form tracking, wearable интеграцыг шат дараатай нэмнэ.
