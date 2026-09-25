#!/bin/bash
# This script does the job of clearpath-robot.service without systemd:
#   1. It copies the config into /etc/clearpath.
#   2-4. It runs the Clearpath generators, and starts a zenoh router
#        between them when zenoh is enabled.
#   5. It starts the platform launch and the platform-extras launch.
#   6. It restarts the stack when robot.yaml changes.
# The router, the platform launch and the robot.yaml watch are supervised. If
# one of them exits, the container exits non-zero and the restart policy
# starts it again.
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
    # The router stops last so the nodes can shut down cleanly through it.
    [ -n "$router_pid" ] && kill -TERM "$router_pid" 2>/dev/null && wait "$router_pid" 2>/dev/null
    echo "entrypoint: stopped"
    return 0
}
trap 'stopping=1; stop_all; exit 0' INT TERM

# 1. Copy the config. The middleware profile must be in place before
#    robot.yaml is parsed, because the parser checks that the file exists.
if [ ! -f "$CONFIG_DIR/robot.yaml" ]; then
    echo "entrypoint: no $CONFIG_DIR/robot.yaml -- mount the directory holding it at $CONFIG_DIR" >&2
    exit 1
fi
cp "$CONFIG_DIR/robot.yaml" /etc/clearpath/robot.yaml
[ -f "$CONFIG_DIR/zenoh_router.json5" ] && cp "$CONFIG_DIR/zenoh_router.json5" /etc/clearpath/zenoh_router.json5

# 2. Generate the ROS environment and the middleware start files.
source /opt/ros/jazzy/setup.bash
source /opt/husky_ws/install/setup.bash
ros2 run clearpath_generator_common generate_bash
source /etc/clearpath/setup.bash
source /opt/husky_ws/install/setup.bash
ros2 run clearpath_generator_common generate_discovery_server
ros2 run clearpath_generator_common generate_zenoh_router

# 3. This step only runs when zenoh is enabled. A router must be running
#    before the remaining generators, or generate_semantic_description aborts
#    when it exits. The script starts a router unless port 7447 is already
#    taken or START_ZENOH_ROUTER=0. Otherwise it waits for the host's router.
if [ "$RMW_IMPLEMENTATION" = rmw_zenoh_cpp ] && [ "${START_ZENOH_ROUTER:-1}" = 1 ]; then
    if (exec 3<>/dev/tcp/127.0.0.1/7447) 2>/dev/null; then
        echo "entrypoint: something already listens on 7447, not starting rmw_zenohd"
    else
        eval "$(grep '^export ZENOH_' /etc/clearpath/zenoh-router-start)"
        # rmw_zenohd runs directly, not through `ros2 run`, so that it
        # receives the stop signal.
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

# 4. Run the remaining generators.
ros2 run clearpath_generator_common generate_vcan
ros2 run clearpath_generator_common generate_description
ros2 run clearpath_generator_common generate_semantic_description
ros2 run clearpath_generator_robot generate_param
ros2 run clearpath_generator_robot generate_launch
echo "entrypoint: generated /etc/clearpath from $CONFIG_DIR/robot.yaml (RMW_IMPLEMENTATION=$RMW_IMPLEMENTATION, ROS_DOMAIN_ID=$ROS_DOMAIN_ID)"

# From here on, failures are handled explicitly. With set -e still on, a
# failed kill inside stop_all would end the script before the nodes stop.
set +e

# 5. Start the launches. set -m gives each child the default SIGINT handling,
#    so `ros2 launch` shuts its nodes down on INT. The extras launch is not
#    supervised, because it exits immediately when robot.yaml has no extras.
set -m
ros2 launch /etc/clearpath/platform/launch/platform-service.launch.py &
launch_pid=$!
extras=/etc/clearpath/platform-extras/launch/platform-extras-service.launch.py
if [ -f "$extras" ]; then
    ros2 launch "$extras" &
    extras_pid=$!
fi
set +m

# 6. Exit when robot.yaml changes. The restart policy then starts the
#    container again, which regenerates everything from the new config.
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
