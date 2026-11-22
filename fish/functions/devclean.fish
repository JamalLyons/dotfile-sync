# Clean developer junk/caches. Dry run by default.
# Usage: devclean [--run] [--yes]   (targets live in ~/bin/devclean.sh)
function devclean
    $HOME/bin/devclean.sh $argv
end
