# Sets up the ROS environment for `docker exec` shells. It is sourced from
# /etc/bash.bashrc for interactive shells and through BASH_ENV for
# non-interactive ones. The generated /etc/clearpath/setup.bash is sourced
# first and the source-built overlay last, so the overlay takes precedence.
# Sourcing it more than once has no effect.
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
