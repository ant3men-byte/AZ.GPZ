#pragma once
// Portable, dependency-free primitives shared by iOS and Linux tests.
#include <cstdint>
#include <optional>
#include <string>

namespace azgps {

struct Coordinate {
    double latitude  = 0.0;
    double longitude = 0.0;
    bool   isValid() const {
        return latitude >= -90.0 && latitude <= 90.0
            && longitude >= -180.0 && longitude <= 180.0;
    }
};

constexpr double kEarthMeanRadiusMeters = 6371008.8;

// --- GeoMath ---
double haversineDistanceMeters(const Coordinate& from, const Coordinate& to);

// --- MovementMath ---
double initialBearingDegrees(const Coordinate& from, const Coordinate& to);
Coordinate destinationPoint(const Coordinate& from, double bearingDegrees, double distanceMeters);
Coordinate interpolateGreatCircle(const Coordinate& from, const Coordinate& to, double fraction);
double clampFraction(double fraction);

// --- TransitionRules ---
enum class SimulationMode { None = 0, Static = 1, Movement = 2, Random = 3, Route = 4 };
/// True when starting 'newMode' conflicts with 'activeMode' (spec §29).
bool isModeConflict(SimulationMode newMode, SimulationMode activeMode);

// --- Location schema validation (mirrors AZLocationModel rules, §27) ---
struct Favorite { std::string id, name; double lat, lon; };
bool validateFavorite(const std::string& schema, bool idIsString, bool nameIsString,
                      bool latIsNumber, bool lonIsNumber, double lat, double lon);

} // namespace azgps

namespace azgps {
inline bool scheduleDue(int scheduledMinute, int currentMinute, int weekday, unsigned dayMask, bool alreadyFired) {
    return scheduledMinute>=0 && scheduledMinute<1440 && currentMinute>=0 && currentMinute<1440
        && weekday>=1 && weekday<=7 && scheduledMinute==currentMinute
        && (dayMask & (1u << (weekday-1))) && !alreadyFired;
}
}
