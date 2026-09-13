#include "Portable.h"
#include <cmath>

namespace azgps {

static constexpr double kDegToRad = M_PI / 180.0;
static constexpr double kRadToDeg = 180.0 / M_PI;

double haversineDistanceMeters(const Coordinate& from, const Coordinate& to) {
    const double lat1 = from.latitude * kDegToRad;
    const double lat2 = to.latitude * kDegToRad;
    const double dLat = (to.latitude - from.latitude) * kDegToRad;
    const double dLon = (to.longitude - from.longitude) * kDegToRad;
    const double a = std::sin(dLat / 2) * std::sin(dLat / 2)
                   + std::cos(lat1) * std::cos(lat2) * std::sin(dLon / 2) * std::sin(dLon / 2);
    return 2.0 * kEarthMeanRadiusMeters * std::asin(std::sqrt(std::min(1.0, a)));
}

double initialBearingDegrees(const Coordinate& from, const Coordinate& to) {
    const double lat1 = from.latitude * kDegToRad;
    const double lat2 = to.latitude * kDegToRad;
    const double dLon = (to.longitude - from.longitude) * kDegToRad;
    const double y = std::sin(dLon) * std::cos(lat2);
    const double x = std::cos(lat1) * std::sin(lat2)
                   - std::sin(lat1) * std::cos(lat2) * std::cos(dLon);
    return std::fmod(std::atan2(y, x) * kRadToDeg + 360.0, 360.0);
}

Coordinate destinationPoint(const Coordinate& from, double bearingDegrees, double distanceMeters) {
    const double lat1 = from.latitude * kDegToRad;
    const double lon1 = from.longitude * kDegToRad;
    const double theta = bearingDegrees * kDegToRad;
    const double delta = distanceMeters / kEarthMeanRadiusMeters;

    const double lat2 = std::asin(std::sin(lat1) * std::cos(delta)
                        + std::cos(lat1) * std::sin(delta) * std::cos(theta));
    const double lon2 = lon1 + std::atan2(std::sin(theta) * std::sin(delta) * std::cos(lat1),
                        std::cos(delta) - std::sin(lat1) * std::sin(lat2));
    return { lat2 * kRadToDeg,
             std::fmod(lon2 * kRadToDeg + 540.0, 360.0) - 180.0 };
}

Coordinate interpolateGreatCircle(const Coordinate& from, const Coordinate& to, double fraction) {
    fraction = clampFraction(fraction);
    if (fraction <= 0.0) return from;
    if (fraction >= 1.0) return to;

    const double lat1 = from.latitude * kDegToRad, lon1 = from.longitude * kDegToRad;
    const double lat2 = to.latitude * kDegToRad,   lon2 = to.longitude * kDegToRad;
    const double d = 2.0 * std::asin(std::sqrt(
        std::sin((lat2 - lat1) / 2) * std::sin((lat2 - lat1) / 2)
      + std::cos(lat1) * std::cos(lat2) * std::sin((lon2 - lon1) / 2) * std::sin((lon2 - lon1) / 2)));
    if (d < 1e-12) return to;

    const double A = std::sin((1.0 - fraction) * d) / std::sin(d);
    const double B = std::sin(fraction * d) / std::sin(d);
    const double x = A * std::cos(lat1) * std::cos(lon1) + B * std::cos(lat2) * std::cos(lon2);
    const double y = A * std::cos(lat1) * std::sin(lon1) + B * std::cos(lat2) * std::sin(lon2);
    const double z = A * std::sin(lat1) + B * std::sin(lat2);
    return { std::atan2(z, std::sqrt(x * x + y * y)) * kRadToDeg,
             std::atan2(y, x) * kRadToDeg };
}

double clampFraction(double fraction) {
    return fraction < 0.0 ? 0.0 : (fraction > 1.0 ? 1.0 : fraction);
}

bool isModeConflict(SimulationMode newMode, SimulationMode activeMode) {
    if (activeMode == SimulationMode::None) return false;
    if (newMode == SimulationMode::Static)  return false; // static overrides, caller stops others
    if (newMode == SimulationMode::None)    return false; // restore default always permitted
    switch (newMode) {
        case SimulationMode::Movement:
            return activeMode == SimulationMode::Route || activeMode == SimulationMode::Random;
        case SimulationMode::Random:
            return activeMode == SimulationMode::Route || activeMode == SimulationMode::Movement;
        case SimulationMode::Route:
            return activeMode == SimulationMode::Movement || activeMode == SimulationMode::Random;
        default: return false;
    }
}

bool validateFavorite(const std::string& schema, bool idIsString, bool nameIsString,
                      bool latIsNumber, bool lonIsNumber, double lat, double lon) {
    if (schema != "azgps.location/1") return false;
    if (!idIsString || !nameIsString)  return false;
    if (!latIsNumber || !lonIsNumber)  return false;   // type validation
    if (lat < -90.0 || lat > 90.0)     return false;   // range validation
    if (lon < -180.0 || lon > 180.0)   return false;
    return true;
}

} // namespace azgps
