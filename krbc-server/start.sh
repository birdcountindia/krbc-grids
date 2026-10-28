#!/bin/sh
# Runs the KRBC reservation API with PHP's built-in web server.
# Only needed when this server doesn't already serve PHP websites (Apache or nginx
# with PHP). Every request goes to krbc-api.php, so the data files are never served.
#
#   sh start.sh            # port 8080
#   PORT=9000 sh start.sh  # another port

cd "$(dirname "$0")" || exit 1
PORT="${PORT:-8080}"
echo "KRBC reservation API: http://localhost:$PORT/krbc-api.php (Ctrl+C to stop)"
exec php -S 0.0.0.0:"$PORT" krbc-api.php
