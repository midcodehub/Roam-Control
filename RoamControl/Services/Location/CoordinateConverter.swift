import CoreLocation
import Foundation

/// 高精度 GCJ-02 与 WGS-84 坐标系互相转换工具。
///
/// 注意：苹果地图（MapKit）在中国大陆境内返回 GCJ-02 坐标，而 iOS 底层
/// CoreLocation / 定位模拟服务使用的是 WGS-84 坐标，因此注入前需要逆向纠偏。
/// 港、澳、台及境外区域 MapKit 使用 WGS-84，无需也不应纠偏。
struct CoordinateConverter: Sendable {
    // 克拉索夫斯基 1940 椭球长半轴与偏心率平方
    private static let a: Double = 6378245.0
    private static let ee: Double = 0.00669342162296594323

    /// 香港特别行政区近似边界（纬度, 经度），顺时针。
    /// 北侧沿深圳河/深圳湾中线，刻意避开深圳福田、罗湖、盐田等大陆区域。
    private static let hongKongPolygon: [(lat: Double, lon: Double)] = [
        (22.100, 113.830),
        (22.350, 113.820),
        (22.440, 113.870),
        (22.470, 113.930),
        (22.482, 113.950),
        (22.505, 114.000),
        (22.510, 114.040),
        (22.515, 114.075),
        (22.530, 114.150),
        (22.545, 114.225),
        (22.560, 114.300),
        (22.560, 114.450),
        (22.100, 114.450)
    ]

    /// 判断坐标是否位于港、澳、台（这些地区不使用 GCJ-02 加偏）。
    static func isInHongKongMacauTaiwan(lat: Double, lon: Double) -> Bool {
        // 台湾本岛、澎湖、兰屿、绿岛一带
        if lat >= 21.8 && lat <= 25.4 && lon >= 119.3 && lon <= 122.1 {
            return true
        }
        // 澳门半岛（北界为关闸，紧邻珠海拱北，因此上限取 22.2155）
        if lat >= 22.170 && lat <= 22.2155 && lon >= 113.525 && lon <= 113.565 {
            return true
        }
        // 澳门氹仔、路环（西侧的横琴岛属于大陆，经度下限取 113.555 以排除）
        if lat >= 22.100 && lat < 22.170 && lon >= 113.555 && lon <= 113.600 {
            return true
        }
        return isInside(lat: lat, lon: lon, polygon: hongKongPolygon)
    }

    /// 判断坐标是否在中国大陆境外（或港澳台等不使用 GCJ-02 的区域）。
    /// - Parameters:
    ///   - lat: 纬度
    ///   - lon: 经度
    ///   - excludeHongKongMacauTaiwan: 为 true 时将港澳台视为"境外"，不做纠偏
    /// - Returns: true 表示无需 GCJ-02 纠偏
    static func isOutOfChina(
        lat: Double,
        lon: Double,
        excludeHongKongMacauTaiwan: Bool = true
    ) -> Bool {
        // 中国经纬度大矩形范围：纬度 0.8293 ~ 55.8271，经度 72.004 ~ 137.8347
        if lon < 72.004 || lon > 137.8347 || lat < 0.8293 || lat > 55.8271 {
            return true
        }
        if excludeHongKongMacauTaiwan, isInHongKongMacauTaiwan(lat: lat, lon: lon) {
            return true
        }
        return false
    }

    /// WGS-84 转 GCJ-02（正向加偏）
    static func wgs84ToGcj02(lat: Double, lon: Double) -> CLLocationCoordinate2D {
        if isOutOfChina(lat: lat, lon: lon) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        let offset = delta(lat: lat, lon: lon)
        return CLLocationCoordinate2D(
            latitude: lat + offset.dLat,
            longitude: lon + offset.dLon
        )
    }

    /// GCJ-02 转 WGS-84（逆向纠偏）。
    /// 以克拉索夫斯基椭球偏移公式为正向模型，做 3 次不动点迭代，残差在毫米级。
    static func gcj02ToWgs84(lat: Double, lon: Double) -> CLLocationCoordinate2D {
        if isOutOfChina(lat: lat, lon: lon) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }

        var wgsLat = lat
        var wgsLon = lon
        for _ in 0..<3 {
            let offset = delta(lat: wgsLat, lon: wgsLon)
            wgsLat = lat - offset.dLat
            wgsLon = lon - offset.dLon
        }
        return CLLocationCoordinate2D(latitude: wgsLat, longitude: wgsLon)
    }

    /// 开关开启且位于中国大陆境内时，将 GCJ-02 逆转为 WGS-84；否则原样返回。
    static func convertToWGS84IfNeeded(
        coordinate: CLLocationCoordinate2D,
        autoConvert: Bool
    ) -> CLLocationCoordinate2D {
        guard autoConvert, !isOutOfChina(lat: coordinate.latitude, lon: coordinate.longitude) else {
            return coordinate
        }
        return gcj02ToWgs84(lat: coordinate.latitude, lon: coordinate.longitude)
    }

    // MARK: - 内部计算

    private struct CoordinateDelta {
        let dLat: Double
        let dLon: Double
    }

    private static func isInside(
        lat: Double,
        lon: Double,
        polygon: [(lat: Double, lon: Double)]
    ) -> Bool {
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            if (a.lat > lat) != (b.lat > lat),
               lon < (b.lon - a.lon) * (lat - a.lat) / (b.lat - a.lat) + a.lon {
                inside.toggle()
            }
            previous = current
        }
        return inside
    }

    private static func delta(lat: Double, lon: Double) -> CoordinateDelta {
        var dLat = transformLat(x: lon - 105.0, y: lat - 35.0)
        var dLon = transformLon(x: lon - 105.0, y: lat - 35.0)
        let radLat = lat / 180.0 * Double.pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * Double.pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * Double.pi)
        return CoordinateDelta(dLat: dLat, dLon: dLon)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * Double.pi) + 40.0 * sin(y / 3.0 * Double.pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * Double.pi) + 320.0 * sin(y * Double.pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * Double.pi) + 20.0 * sin(2.0 * x * Double.pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * Double.pi) + 40.0 * sin(x / 3.0 * Double.pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * Double.pi) + 300.0 * sin(x / 30.0 * Double.pi)) * 2.0 / 3.0
        return ret
    }
}
