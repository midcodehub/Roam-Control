#!/usr/bin/env python3
"""Compile the production CoordinateConverter and check conversion accuracy and region boundaries."""
from pathlib import Path
import subprocess, tempfile

root = Path(__file__).resolve().parents[1]
source = root / 'RoamControl/Services/Location/CoordinateConverter.swift'

main = r'''
import CoreLocation
import Foundation

func metres(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
    CLLocation(latitude: a.latitude, longitude: a.longitude)
        .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
}

// 1. Round trip WGS -> GCJ -> WGS must be sub-centimetre across mainland China.
var worst = 0.0
var lat = 18.0
while lat < 53.0 {
    var lon = 75.0
    while lon < 134.0 {
        if !CoordinateConverter.isOutOfChina(lat: lat, lon: lon) {
            let gcj = CoordinateConverter.wgs84ToGcj02(lat: lat, lon: lon)
            let back = CoordinateConverter.gcj02ToWgs84(lat: gcj.latitude, lon: gcj.longitude)
            worst = max(worst, metres(back, CLLocationCoordinate2D(latitude: lat, longitude: lon)))
        }
        lon += 0.37
    }
    lat += 0.29
}
precondition(worst < 0.01, "round trip error \(worst) m")

// 2. Mainland offsets are real (tens to hundreds of metres), not zero.
let beijing = CLLocationCoordinate2D(latitude: 39.9087, longitude: 116.3975)
let beijingOffset = metres(beijing, CoordinateConverter.wgs84ToGcj02(lat: beijing.latitude, lon: beijing.longitude))
precondition(beijingOffset > 100 && beijingOffset < 1000, "Beijing offset \(beijingOffset) m")

// 3. Mainland cities next to Hong Kong / Macau must still be corrected.
let mainland: [(String, Double, Double)] = [
    ("Shenzhen Futian", 22.5431, 114.0579),
    ("Shenzhen Luohu", 22.5310, 114.1230),
    ("Shenzhen Nanshan Shekou", 22.4800, 113.9200),
    ("Shenzhen Yantian", 22.5700, 114.2500),
    ("Zhuhai Gongbei", 22.2250, 113.5500),
    ("Zhuhai Hengqin", 22.1337, 113.5435),
    ("Guangzhou", 23.1291, 113.2644),
    ("Fuzhou", 26.0745, 119.2965),
]
for (name, la, lo) in mainland {
    precondition(!CoordinateConverter.isOutOfChina(lat: la, lon: lo), "\(name) must count as mainland")
    let moved = metres(
        CLLocationCoordinate2D(latitude: la, longitude: lo),
        CoordinateConverter.wgs84ToGcj02(lat: la, lon: lo)
    )
    precondition(moved > 50, "\(name) was not shifted (\(moved) m)")
}

// 4. Hong Kong, Macau, Taiwan and overseas are never shifted.
let untouched: [(String, Double, Double)] = [
    ("Hong Kong Central", 22.2819, 114.1580),
    ("Hong Kong Kowloon", 22.3193, 114.1694),
    ("Hong Kong Yuen Long", 22.4450, 114.0300),
    ("Hong Kong Tai O", 22.2530, 113.8620),
    ("Macau Peninsula", 22.1987, 113.5439),
    ("Macau Cotai", 22.1465, 113.5617),
    ("Taipei", 25.0330, 121.5654),
    ("Penghu", 23.5711, 119.5793),
    ("Tokyo", 35.6762, 139.6503),
    ("London", 51.5074, -0.1278),
]
for (name, la, lo) in untouched {
    precondition(CoordinateConverter.isOutOfChina(lat: la, lon: lo), "\(name) must not be corrected")
    let converted = CoordinateConverter.gcj02ToWgs84(lat: la, lon: lo)
    precondition(converted.latitude == la && converted.longitude == lo, "\(name) was modified")
}

// 5. The convenience entry honours the user toggle.
let input = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
let off = CoordinateConverter.convertToWGS84IfNeeded(coordinate: input, autoConvert: false)
precondition(off.latitude == input.latitude && off.longitude == input.longitude)
let on = CoordinateConverter.convertToWGS84IfNeeded(coordinate: input, autoConvert: true)
precondition(metres(input, on) > 50)

print("round-trip worst error: \(worst) m")
print("Coordinate converter checks passed")
'''

with tempfile.TemporaryDirectory() as temp:
    work = Path(temp)
    (work / 'main.swift').write_text(main)
    binary = work / 'check'
    subprocess.run(['swiftc', '-O', str(source), str(work / 'main.swift'), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
