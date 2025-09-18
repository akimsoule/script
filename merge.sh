commit.sh

current_branch=$(git symbolic-ref --short HEAD)

git checkout main
git merge develop/main
git push origin main

git checkout $current_branch
