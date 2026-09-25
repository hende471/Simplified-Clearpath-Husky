# simplified-husky

Run the Clearpath Husky A200 platform stack in Docker on any companion
computer (Raspberry Pi 5, Jetson, x86). No Clearpath ISO, no systemd.

Clearpath ships the robot-side packages for amd64 only. This image installs
everything else from `packages.ros.org` and builds the rest
(`clearpath_hardware_interfaces`, `clearpath_generator_robot`,
`clearpath_sensors`) from [`clearpath_robot`](https://github.com/clearpathrobotics/clearpath_robot)
source, so it runs on arm64 and amd64.

## Architecture

```
 +--------------------------+           +-------------------------------------------+
 |      Husky A200 base     |           |        Companion computer (Docker)        |
 |                          |  USB-     |  container: husky-platform                |
 |  +--------------------+  |  serial   |                                           |
 |  |  MCU               |<-+-----------+->  A200Hardware (ros2_control plugin)      |
 |  |  motor drivers     |  |  PL2303   |      |                                    |
 |  |  encoders, battery |  |           |   diff_drive controller -> odom            |
 |  |  e-stop            |  |           |      ^                |                   |
 |  +--------------------+  |           |   twist_mux        EKF (odom/filtered)     |
 |                          |           |      ^                                    |
 +--------------------------+           |   teleop <- joy_linux <----+              |
                                        |                             |             |
                                        |   robot_state_publisher, diagnostics,     |
                                        |   foxglove_bridge :8765, wireless_watcher |
                                        +-----------------------------+-------------+
                                                   Bluetooth |        | ROS 2 (host network)
                                                             |        | Fast DDS (default)
                                                     +-------+---+    | or zenoh (optional)
                                                     | PS4 / PS5 |    v
                                                     | gamepad   |  other ROS 2 machines
                                                     +-----------+  (navigation, sensors, ...)
```

All topics live under `/a200_0000/` (`robot.yaml` `system.ros2.namespace`).
To change it, update `system.ros2.namespace` in `robot.yaml`; the container
restarts with the new namespace.

## Files

| file | purpose |
|---|---|
| `Dockerfile` | ROS 2 Jazzy + Clearpath packages, source build of `clearpath_robot` |
| `entrypoint.sh` | generates `/etc/clearpath` from `robot.yaml`, starts the platform launch |
| `compose.yaml` | service: host network, `/dev`, RT priority, restart policy |
| `robot.yaml` | Clearpath robot config |
| `zenoh_router.json5` | zenoh router config (optional) |
| `ros_env.sh` | ROS env for `docker exec` shells |
| `host/70-clearpath-husky.rules` | udev: `/dev/clearpath/prolific`, `/dev/input/ps5` |
| `native/install.sh` | native install on Ubuntu 24.04, no Docker |
| `native/husky-platform@.service` | systemd unit for the native install |

## Setup (Docker)

1. Install Docker with the compose plugin.
2. Install the udev rules:
   ```bash
   sudo cp host/70-clearpath-husky.rules /etc/udev/rules.d/
   sudo udevadm control --reload-rules && sudo udevadm trigger
   ```
   Kernel modules: `pl2303`, `joydev`, `hid-playstation`.
3. Check the hidraw major matches `compose.yaml` (`242`):
   `grep hidraw /proc/devices`.
4. Pair the gamepad (hold Create + PS until the light bar flashes):
   ```
   bluetoothctl
   agent on
   default-agent
   scan on
   pair <MAC>        # while scan is still on
   trust <MAC>
   connect <MAC>
   scan off
   ```
5. Plug the MCU cable into the companion computer and start:
   ```bash
   docker compose up -d --build
   ```

Power on the Husky base before the container starts. The container does not
retry the MCU; if the base was off, run `docker compose restart`.

## Native install (systemd, no Docker)

Requires Ubuntu 24.04 (arm64 or amd64). Runs the same `entrypoint.sh` as the
container, as a systemd service.

```bash
./native/install.sh
```

It installs the ROS 2 and Clearpath packages, builds `clearpath_robot` in
`/opt/husky_ws`, installs the udev rules, copies `robot.yaml` and
`zenoh_router.json5` to `/etc/husky_platform/` (existing files are kept),
and enables `husky-platform@$USER.service`. Pair the gamepad as in step 4
above.

| path | purpose |
|---|---|
| `/etc/husky_platform/robot.yaml` | robot config; editing it restarts the service |
| `/etc/clearpath/` | generated config, rewritten on every start |
| `/opt/husky_platform/` | `entrypoint.sh`, `ros_env.sh` |
| `/var/log/husky-platform/` | ROS logs |

```bash
systemctl status husky-platform@$USER
journalctl -fu husky-platform@$USER
sudo systemctl restart husky-platform@$USER
sudo systemctl disable --now husky-platform@$USER
source /opt/husky_platform/ros_env.sh    # ROS environment in a shell
```

As with the container, the service does not retry the MCU. If the base was
off when it started, restart the service.

Do not run the native service and the container at the same time.

## Usage

```bash
docker compose logs -f
docker exec husky-platform bash -c 'ros2 topic hz /a200_0000/platform/odom'
docker exec husky-platform bash -c 'ros2 control list_controllers -c /a200_0000/controller_manager'
docker compose down
```

Drive: hold **L1** + left stick. **R1** = turbo. The robot stops if the
Bluetooth link quality drops below 40 %.

Editing `robot.yaml` restarts the container with the regenerated config.

## Middleware

**Fast DDS** (default): no `middleware:` block in `robot.yaml`. Simple
discovery; other machines need the same `ROS_DOMAIN_ID` and must be on the
same network.

**zenoh** (optional): uncomment the `middleware:` block in `robot.yaml`.
The container starts `rmw_zenohd` with `zenoh_router.json5`, or joins an
existing router on `localhost:7447`. To always use the host's router, set
`START_ZENOH_ROUTER` to `0` in `compose.yaml`, or in the systemd unit for a
native install. Other machines connect with
`ZENOH_CONFIG_OVERRIDE='connect/endpoints=["tcp/<robot-ip>:7447"]'`.

## Notes

- Run only one platform stack per robot.
- On a Raspberry Pi, use an adequate 5 V / 5 A supply. Undervoltage can
  reboot the Pi during a full image build.
- New apt packages go in the last `RUN` layer of the `Dockerfile` to avoid a
  full rebuild.

## License

MIT, see [LICENSE](LICENSE). The udev rules are adapted from Clearpath's
`clearpath_robot` (BSD-3-Clause), and `zenoh_router.json5` is adapted from
`rmw_zenoh` (Apache-2.0). The Clearpath packages the image builds and
installs keep their own licenses.
