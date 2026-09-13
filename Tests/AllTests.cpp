#include "../src/Portable.h"
#include <cstdio>
#include <cmath>
#include <string>

static int wf_failures = 0;
static int wf_checks   = 0;

#define AZ_CHECK(cond, msg) do { ++wf_checks;                                   \
    if (!(cond)) { ++wf_failures;                                               \
        std::printf("FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)

#define AZ_CHECK_NEAR(actual, expected, eps, msg) do { ++wf_checks;             \
    double _a = (actual), _e = (expected), _d = (eps);                          \
    if (!(std::fabs(_a - _e) <= _d)) { ++wf_failures;                           \
        std::printf("FAIL: %s (line %d): actual=%f expected=%f\n",              \
                    msg, __LINE__, _a, _e); } } while (0)

static int wf_report(const char *suite) {
    std::printf("[%s] %d checks, %d failures\n", suite, wf_checks, wf_failures);
    return wf_failures == 0 ? 0 : 1;
}

int main() {
    using namespace azgps;
    const double kEps = 1e-6;

    // ---- GeoMath ----
    AZ_CHECK_NEAR(haversineDistanceMeters({0,0},{0,0}), 0.0, kEps, "zero distance");
    AZ_CHECK_NEAR(haversineDistanceMeters({0,0},{1,0}), 111195.0, 500.0, "1 deg latitude");
    AZ_CHECK_NEAR(haversineDistanceMeters({52.52,13.405},{48.8566,2.3522}),
                  878000.0, 3000.0, "Berlin-Paris");
    AZ_CHECK(haversineDistanceMeters({0,0},{10,10}) > haversineDistanceMeters({0,0},{5,5}),
             "distance monotonic");

    // ---- Movement: bearing ----
    AZ_CHECK_NEAR(initialBearingDegrees({0,0},{1,0}), 0.0, 0.5, "bearing north = 0");
    AZ_CHECK_NEAR(initialBearingDegrees({0,0},{0,1}), 90.0, 0.5, "bearing east = 90");

    // ---- Movement: destination point ----
    Coordinate dest = destinationPoint({0,0}, 0.0, 111195.0);
    AZ_CHECK_NEAR(dest.latitude, 1.0, 0.01, "destination north 1 deg");
    AZ_CHECK(dest.isValid(), "destination valid");

    // ---- Movement: interpolation ----
    Coordinate mid = interpolateGreatCircle({0,0},{2,0}, 0.5);
    AZ_CHECK_NEAR(mid.latitude, 1.0, 0.01, "midpoint latitude");
    AZ_CHECK_NEAR(interpolateGreatCircle({0,0},{2,0}, 0.0).latitude, 0.0, kEps, "f=0 start");
    AZ_CHECK_NEAR(interpolateGreatCircle({0,0},{2,0}, 1.0).latitude, 2.0, kEps, "f=1 end");
    AZ_CHECK(interpolateGreatCircle({0,0},{2,0}, 5.0).latitude <= 2.0, "f clamped high");
    AZ_CHECK(interpolateGreatCircle({0,0},{2,0}, -5.0).latitude >= 0.0, "f clamped low");
    AZ_CHECK(interpolateGreatCircle({0,0},{2,0}, 0.5).isValid(), "interp point valid");

    // ---- Movement: monotonic progress + clamp ----
    double prevLat = 0.0;
    for (double f = 0.25; f <= 1.0; f += 0.25) {
        Coordinate p = interpolateGreatCircle({0,0},{2,0}, f);
        AZ_CHECK(p.latitude > prevLat, "progress monotonic");
        prevLat = p.latitude;
    }
    AZ_CHECK_NEAR(clampFraction(-1.0), 0.0, kEps, "clamp low");
    AZ_CHECK_NEAR(clampFraction(0.5), 0.5, kEps, "clamp passthrough");
    AZ_CHECK_NEAR(clampFraction(2.0), 1.0, kEps, "clamp high");

    // ---- Transition rules ----
    AZ_CHECK(!isModeConflict(SimulationMode::Movement, SimulationMode::None),
             "no conflict when idle");
    AZ_CHECK(!isModeConflict(SimulationMode::None, SimulationMode::Movement),
             "restore default never conflicts");
    AZ_CHECK(isModeConflict(SimulationMode::Movement, SimulationMode::Route),
             "movement conflicts route");
    AZ_CHECK(isModeConflict(SimulationMode::Movement, SimulationMode::Random),
             "movement conflicts random");
    AZ_CHECK(!isModeConflict(SimulationMode::Movement, SimulationMode::Static),
             "movement allowed over static");
    AZ_CHECK(isModeConflict(SimulationMode::Random, SimulationMode::Route),
             "random conflicts route");
    AZ_CHECK(isModeConflict(SimulationMode::Random, SimulationMode::Movement),
             "random conflicts movement");
    AZ_CHECK(isModeConflict(SimulationMode::Route, SimulationMode::Movement),
             "route conflicts movement");
    AZ_CHECK(isModeConflict(SimulationMode::Route, SimulationMode::Random),
             "route conflicts random");
    AZ_CHECK(!isModeConflict(SimulationMode::Static, SimulationMode::Route),
             "static overrides route");
    AZ_CHECK(!isModeConflict(SimulationMode::Static, SimulationMode::Movement),
             "static overrides movement");

    // ---- Location schema validation ----
    AZ_CHECK(validateFavorite("azgps.location/1", true, true, true, true, 52.52, 13.405),
             "valid favorite accepted");
    AZ_CHECK(!validateFavorite("wrong-schema/9", true, true, true, true, 0, 0),
             "wrong schema rejected");
    AZ_CHECK(!validateFavorite("azgps.location/1", false, true, true, true, 0, 0),
             "non-string id rejected");
    AZ_CHECK(!validateFavorite("azgps.location/1", true, true, false, true, 0, 0),
             "non-numeric latitude rejected");
    AZ_CHECK(!validateFavorite("azgps.location/1", true, true, true, false, 0, 0),
             "non-numeric longitude rejected");
    AZ_CHECK(!validateFavorite("azgps.location/1", true, true, true, true, 95.0, 0),
             "out-of-range latitude rejected");
    AZ_CHECK(!validateFavorite("azgps.location/1", true, true, true, true, 0, 200.0),
             "out-of-range longitude rejected");
    AZ_CHECK(validateFavorite("azgps.location/1", true, true, true, true, -90.0, 180.0),
             "boundary coordinates accepted");
    AZ_CHECK(!validateFavorite("azgps.location/1", true, true, true, true, 90.0001, 0),
             "just-outside boundary rejected");

    WF_CHECK(scheduleDue(0,0,1,1,false), "midnight Sunday fires");
    WF_CHECK(scheduleDue(1439,1439,7,64,false), "last minute Saturday fires");
    WF_CHECK(!scheduleDue(600,601,1,127,false), "missed schedule does not replay");
    WF_CHECK(!scheduleDue(600,600,1,127,true), "already fired schedule does not repeat");
    WF_CHECK(!scheduleDue(600,600,2,1,false), "excluded weekday does not fire");
    WF_CHECK(!scheduleDue(-1,0,1,127,false), "negative schedule rejected");
    WF_CHECK(!scheduleDue(1440,1440,1,127,false), "out of range minute rejected");
    WF_CHECK(!scheduleDue(600,600,0,127,false), "invalid weekday rejected");
    WF_CHECK(!scheduleDue(600,600,8,127,false), "weekday above range rejected");
    WF_CHECK(!scheduleDue(600,600,1,0,false), "empty weekdays never fire");
    return wf_report("AZGPS-AllTests");
}
