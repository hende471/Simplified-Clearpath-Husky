#!/bin/bash
# Installs the Husky platform stack directly on an Ubuntu 24.04 host (arm64 or
# amd64) and sets it up as a systemd service. Run it from the repository as
# the user that should own the service, not as root. It asks for sudo where
# it needs it.
#
# The package list and the clearpath_robot build match the Dockerfile. Keep
# the two in sync when you change either one.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
SERVICE_USER=${SERVICE_USER:-$(id -un)}
CLEARPATH_ROBOT_TAG=${CLEARPATH_ROBOT_TAG:-2.9.8}

if [ "$(id -u)" = 0 ]; then
    echo "Run this as the service user, not as root." >&2
    exit 1
fi
. /etc/os-release
if [ "${VERSION_CODENAME:-}" != noble ]; then
    echo "This needs Ubuntu 24.04 (noble); found ${PRETTY_NAME:-unknown}." >&2
    exit 1
fi

echo "==> Installing ROS 2 Jazzy and the Clearpath packages"
sudo apt-get update
sudo apt-get install -y --no-install-recommends curl gnupg2 ca-certificates
if [ ! -f /usr/share/keyrings/ros-archive-keyring.gpg ]; then
    curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        | sudo gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg
fi
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu noble main" \
    | sudo tee /etc/apt/sources.list.d/ros2.list > /dev/null
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    ros-jazzy-ros-base \
    ros-jazzy-rmw-zenoh-cpp \
    ros-jazzy-clearpath-common \
    ros-jazzy-clearpath-config \
    ros-jazzy-clearpath-generator-common \
    ros-jazzy-clearpath-diagnostics \
    ros-jazzy-clearpath-platform-msgs \
    ros-jazzy-clearpath-motor-msgs \
    ros-jazzy-controller-interface \
    ros-jazzy-controller-manager \
    ros-jazzy-controller-manager-msgs \
    ros-jazzy-hardware-interface \
    ros-jazzy-diagnostic-updater \
    ros-jazzy-pluginlib \
    ros-jazzy-tf2-ros \
    ros-jazzy-xacro \
    ros-jazzy-imu-filter-madgwick \
    ros-jazzy-wireless-watcher \
    ros-jazzy-wireless-msgs \
    ros-jazzy-foxglove-bridge \
    ros-jazzy-ros2controlcli \
    python3-apt \
    python3-colcon-common-extensions \
    build-essential cmake git

echo "==> Building clearpath_robot ${CLEARPATH_ROBOT_TAG} in /opt/husky_ws"
# The three packages below are the ones Clearpath publishes for amd64 only.
# The workspace is built in place, at the same path the Docker image uses.
clone_dir=$(mktemp -d)
trap 'rm -rf "$clone_dir"' EXIT
git clone --depth 1 -b "$CLEARPATH_ROBOT_TAG" \
    https://github.com/clearpathrobotics/clearpath_robot.git "$clone_dir/clearpath_robot"
sudo install -d -o "$SERVICE_USER" /opt/husky_ws
mkdir -p /opt/husky_ws/src
cp -r "$clone_dir/clearpath_robot/clearpath_generator_robot" \
      "$clone_dir/clearpath_robot/clearpath_hardware_interfaces" \
      "$clone_dir/clearpath_robot/clearpath_sensors" /opt/husky_ws/src/
(
    cd /opt/husky_ws
    set +u
    source /opt/ros/jazzy/setup.bash
    set -u
    colcon build --merge-install \
        --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
    rm -rf build log
)

echo "==> Installing the entrypoint, the config and the udev rules"
sudo install -D -m 755 "$REPO_DIR/entrypoint.sh" /opt/husky_platform/entrypoint.sh
sudo install -D -m 644 "$REPO_DIR/ros_env.sh" /opt/husky_platform/ros_env.sh
# Existing config files are kept, so re-running this does not undo your edits.
sudo install -d -o "$SERVICE_USER" /etc/husky_platform /etc/clearpath
for f in robot.yaml zenoh_router.json5; do
    if [ ! -f "/etc/husky_platform/$f" ]; then
        install -m 644 "$REPO_DIR/$f" "/etc/husky_platform/$f"
    fi
done
sudo install -m 644 "$REPO_DIR/host/70-clearpath-husky.rules" /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger

echo "==> Installing and enabling husky-platform@${SERVICE_USER}.service"
sudo install -m 644 "$REPO_DIR/native/husky-platform@.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now "husky-platform@${SERVICE_USER}.service"

echo
echo "Done. Edit /etc/husky_platform/robot.yaml to change the robot config."
echo "Follow the logs with: journalctl -fu husky-platform@${SERVICE_USER}"
echo "Add this line to ~/.bashrc to get the ROS environment in new shells:"
echo "  source /opt/husky_platform/ros_env.sh"
