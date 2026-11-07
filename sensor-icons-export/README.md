# sensor-icons-export

조각보 앱의 센서 아이콘 조사 결과입니다. **이 폴더에는 SVG가 없습니다.** 센서 아이콘이 전부 SF Symbols이고,
프로젝트 안에 SVG/PDF 원본이 없으며, 이 작업 환경에서는 SF Symbols 글리프 데이터에 접근할 수 없기 때문입니다.
임의의 대체 아이콘은 만들지 않았습니다.

## 조각보 센서 (SensorKind)

정의: `PogoHome/PogoHome/Core/Models/SensorKind.swift` → `symbolName`

| 센서 | SensorKind | SF Symbol 이름 |
|---|---|---|
| 온도 | `.temperature` | `thermometer.medium` |
| 습도 | `.humidity` | `humidity.fill` |
| 조도 | `.illuminance` | `sun.max.fill` |
| 미세먼지 PM1 / PM2.5 / PM10 | `.pm1` `.pm2_5` `.pm10` | `aqi.medium` (3종 공유) |
| VOC Raw / VOC Index | `.vocRaw` `.vocIndex` | `wind` (2종 공유) |
| NOx Raw / NOx Index | `.noxRaw` `.noxIndex` | `smoke.fill` (2종 공유) |

고유한 심볼은 6개입니다: `thermometer.medium`, `humidity.fill`, `sun.max.fill`, `aqi.medium`, `wind`, `smoke.fill`

## SF Symbols 앱(macOS)에서 직접 내보내는 방법

1. SF Symbols 앱에서 위 6개 이름을 검색합니다.
2. `File ▸ Export Symbol…` 에서 SVG(템플릿 버전 포함)로 내보냅니다.
3. 내보낸 SVG는 weight·scale별 가이드 레이어를 포함하므로, 사용할 weight(앱에서는 주로 Semibold)의 윤곽선 레이어만 남기고 정리합니다.
4. 사용 전에 SF Symbols 앱의 라이선스 문구를 확인하세요. 로고·앱 아이콘·상표 용도 제한이 있는 것으로 알려져 있고, 3D 모델링/제품 설계에 쓰는 것이 허용되는지는 확인하지 못했습니다.
