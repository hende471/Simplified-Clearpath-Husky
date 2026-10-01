# This image runs the Clearpath Husky A200 platform stack on any Docker host,
# arm64 or amd64.
#
# Clearpath publishes the clearpath_robot packages (the A200 hardware plugin,
# the robot-side generator and the sensor configs) for amd64 only. Everything
# else is available on packages.ros.org for both architectures, so this image
# installs it from there and builds the three missing packages from the
# tagged clearpath_robot source.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    ROS_DISTRO=jazzy \
    PYTHONUNBUFFERED=1

SHELL ["/bin/bash", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
        locales curl gnupg2 ca-certificates \
    && locale-gen en_US en_US.UTF-8 \
    && update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# This layer installs ROS 2 Jazzy, the Clearpath packages from the ROS build
# farm, and every package the generated A200 platform launch needs at runtime.
# native/install.sh installs the same list, so keep the two in sync.
RUN curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
        | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu noble main" \
        > /etc/apt/sources.list.d/ros2.list \
    && apt-get update && apt-get install -y --no-install-recommends \
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
        python3-apt \
        python3-colcon-common-extensions \
        build-essential cmake git \
    && rm -rf /var/lib/apt/lists/*

# clearpath_sensors contains only launch and parameter files for the sensors
# Clearpath supports. The Clearpath generators look up its install directory
# even when robot.yaml lists no sensors, so it has to be built. Its sensor
# driver dependencies are not installed, to keep the image small. If you add
# a sensor to robot.yaml, add that sensor's driver package (for example
# ros-jazzy-realsense2-camera) to the last RUN layer below.
ARG CLEARPATH_ROBOT_TAG=2.9.8
WORKDIR /opt/husky_ws
RUN git clone --depth 1 -b "${CLEARPATH_ROBOT_TAG}" \
        https://github.com/clearpathrobotics/clearpath_robot.git /tmp/clearpath_robot \
    && mkdir -p src \
    && cp -r /tmp/clearpath_robot/clearpath_generator_robot \
             /tmp/clearpath_robot/clearpath_hardware_interfaces \
             /tmp/clearpath_robot/clearpath_sensors src/ \
    && rm -rf /tmp/clearpath_robot \
    && source /opt/ros/jazzy/setup.bash \
    && colcon build --merge-install --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
    && rm -rf build log

# Add extra tools and keyboard teleop to this last layer. Changing an earlier
# layer rebuilds every layer after it, which takes a long time on small computers.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ros-jazzy-ros2controlcli \
    ros-jazzy-teleop-twist-keyboard \
    && rm -rf /var/lib/apt/lists/*

# The A100 manual recommends 0.5 m/s^2 max wheel acceleration. The A200
# description defaults to 5.0, which the A100 MCU rejects as out of range.
RUN xacro_file=/opt/ros/jazzy/share/clearpath_platform_description/urdf/a200/a200.urdf.xacro \
    && grep -q '<param name="max_accel">5.0</param>' "$xacro_file" \
    && sed -i 's|<param name="max_accel">5.0</param>|<param name="max_accel">0.5</param>|' "$xacro_file" \
    && rm -rf /var/lib/apt/lists/*

COPY ros_env.sh /opt/husky_platform/ros_env.sh
COPY entrypoint.sh /opt/husky_platform/entrypoint.sh
RUN chmod +x /opt/husky_platform/entrypoint.sh \
    && mkdir -p /etc/clearpath /config \
    && echo 'source /opt/husky_platform/ros_env.sh' >> /etc/bash.bashrc

ENV BASH_ENV=/opt/husky_platform/ros_env.sh \
    ROS_LOG_DIR=/data/ros_logs

VOLUME ["/data"]

ENTRYPOINT ["/opt/husky_platform/entrypoint.sh"]
