commit.sh

current_branch=$(git symbolic-ref --short HEAD)
main=${current_branch%-demo}

git checkout $main
git merge $current_branch
git push origin $main

git checkout $current_branch