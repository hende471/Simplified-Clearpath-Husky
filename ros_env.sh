# ROS environment for `docker exec` shells (via /etc/bash.bashrc and BASH_ENV).
# Generated setup.bash first, source-built overlay last. Idempotent.
case ":${AMENT_PREFIX_PATH:-}:" in
    *:/opt/husky_ws/install:*) ;;
    *)
        if [ -f /etc/clearpath/setup.bash ]; then
            source /etc/clearpath/setup.bash
        else
            source /opt/ros/jazzy/setup.bash
        fi
        source /opt/husky_ws/install/setup.bash
        ;;
esac
