#!/bin/bash
# Replaces clearpath-robot.service without systemd:
#   1. copy config into /etc/clearpath
#   2-4. run the Clearpath generators (zenoh router in between, if zenoh)
#   5. start the platform (+ extras) launch
#   6. restart on robot.yaml change
# The router, platform launch and robot.yaml watch are supervised: if one
# exits, the container exits non-zero and the restart policy brings it back.
set -e

CONFIG_DIR=${CONFIG_DIR:-/config}
mkdir -p "${ROS_LOG_DIR:-/data/ros_logs}"

router_pid=
launch_pid=
extras_pid=
watch_pid=
stopping=
stop_all() {
    set +e
    [ -n "$watch_pid" ] && kill "$watch_pid" 2>/dev/null
    [ -n "$launch_pid" ] && kill -INT "$launch_pid" 2>/dev/null
    [ -n "$extras_pid" ] && kill -INT "$extras_pid" 2>/dev/null
    [ -n "$launch_pid" ] && wait "$launch_pid" 2>/dev/null
    [ -n "$extras_pid" ] && wait "$extras_pid" 2>/dev/null
    # Router last so nodes can shut down cleanly through it.
    [ -n "$router_pid" ] && kill -TERM "$router_pid" 2>/dev/null && wait "$router_pid" 2>/dev/null
    echo "entrypoint: stopped"
    return 0
}
trap 'stopping=1; stop_all; exit 0' INT TERM

# 1. Config. The middleware profile must exist before robot.yaml is parsed.
if [ ! -f "$CONFIG_DIR/robot.yaml" ]; then
    echo "entrypoint: no $CONFIG_DIR/robot.yaml -- mount the directory holding it at $CONFIG_DIR" >&2
    exit 1
fi
cp "$CONFIG_DIR/robot.yaml" /etc/clearpath/robot.yaml
[ -f "$CONFIG_DIR/zenoh_router.json5" ] && cp "$CONFIG_DIR/zenoh_router.json5" /etc/clearpath/zenoh_router.json5

# 2. Environment and middleware start files.
source /opt/ros/jazzy/setup.bash
source /opt/husky_ws/install/setup.bash
ros2 run clearpath_generator_common generate_bash
source /etc/clearpath/setup.bash
source /opt/husky_ws/install/setup.bash
ros2 run clearpath_generator_common generate_discovery_server
ros2 run clearpath_generator_common generate_zenoh_router

# 3. Zenoh only: a router must be up before the remaining generators, or
#    generate_semantic_description aborts on exit. Start one unless port 7447
#    is taken or START_ZENOH_ROUTER=0, otherwise wait for the host's router.
if [ "$RMW_IMPLEMENTATION" = rmw_zenoh_cpp ] && [ "${START_ZENOH_ROUTER:-1}" = 1 ]; then
    if (exec 3<>/dev/tcp/127.0.0.1/7447) 2>/dev/null; then
        echo "entrypoint: something already listens on 7447, not starting rmw_zenohd"
    else
        eval "$(grep '^export ZENOH_' /etc/clearpath/zenoh-router-start)"
        # Run rmw_zenohd directly so it receives the stop signal.
        "$(ros2 pkg prefix rmw_zenoh_cpp)/lib/rmw_zenoh_cpp/rmw_zenohd" > "$ROS_LOG_DIR/rmw_zenohd.log" 2>&1 &
        router_pid=$!
        echo "entrypoint: rmw_zenohd started (pid $router_pid, config ${ZENOH_ROUTER_CONFIG_URI:-default}, log $ROS_LOG_DIR/rmw_zenohd.log)"
        sleep 2
    fi
fi

if [ "$RMW_IMPLEMENTATION" = rmw_zenoh_cpp ] && [ -z "$router_pid" ]; then
    waited=0
    until (exec 3<>/dev/tcp/127.0.0.1/7447) 2>/dev/null; do
        [ $((waited % 10)) = 0 ] && echo "entrypoint: waiting for a zenoh router on localhost:7447 (${waited} s)"
        sleep 1
        waited=$((waited + 1))
    done
    echo "entrypoint: zenoh router on localhost:7447 is up, joining it"
fi

# 4. Remaining generators.
ros2 run clearpath_generator_common generate_vcan
ros2 run clearpath_generator_common generate_description
ros2 run clearpath_generator_common generate_semantic_description
ros2 run clearpath_generator_robot generate_param
ros2 run clearpath_generator_robot generate_launch
echo "entrypoint: generated /etc/clearpath from $CONFIG_DIR/robot.yaml (RMW_IMPLEMENTATION=$RMW_IMPLEMENTATION, ROS_DOMAIN_ID=$ROS_DOMAIN_ID)"

# Failures are handled explicitly from here; set -e would abort stop_all.
set +e

# 5. Launches. set -m gives each child default SIGINT handling so
#    `ros2 launch` shuts its nodes down on INT. Extras is not supervised: it
#    exits at once when robot.yaml has no extras.
set -m
ros2 launch /etc/clearpath/platform/launch/platform-service.launch.py &
launch_pid=$!
extras=/etc/clearpath/platform-extras/launch/platform-extras-service.launch.py
if [ -f "$extras" ]; then
    ros2 launch "$extras" &
    extras_pid=$!
fi
set +m

# 6. Exit on robot.yaml change; the restart policy regenerates everything.
(
    m1=$(md5sum < "$CONFIG_DIR/robot.yaml")
    while sleep 1; do
        [ "$(md5sum < "$CONFIG_DIR/robot.yaml")" = "$m1" ] || { echo "entrypoint: robot.yaml changed, restarting" >&2; exit 3; }
    done
) &
watch_pid=$!

status=0
wait -n $launch_pid $router_pid $watch_pid || status=$?
[ -n "$stopping" ] && exit 0
[ "$status" = 0 ] && status=1
echo "entrypoint: a supervised process exited (status $status), stopping the stack" >&2
stop_all
exit $status
