# Makefile to create repos and sample data
SFSCHEMA=./demo_db/demo_schema
LOCALBRANCH := local-dev
BRANCHES := dev tst
MASTERBRANCH := prd
reverse = $(if $(wordlist 2,2,$(1)),$(call reverse,$(wordlist 2,$(words $(1)),$(1))) $(firstword $(1)),$(1))

.phony: all
all: check-dependencies git-repo parse-git

check-dependencies:
	@echo 'git version should be larger than 2.28'
	@git --version 
	@./bin/testgitversion.sh

git-repo: 
	mkdir -p cdw-src
	mkdir -p branch-output
	mkdir -p cicd-output
	cd cdw-src; \
		git init -b ${MASTERBRANCH}; \
		cp ../git-post-merge-hook .git/hooks/post-merge;
	cd cdw-src; \
		mkdir -p demo_db/demo_schema; \
		cp ../objects/init/* $(SFSCHEMA); \
		git add --all; \
		git commit -m 'Import initial state';
	cd cdw-src/; \
		for BRANCH in $(call reverse,${LOCALBRANCH} ${BRANCHES}) ; do \
			git branch $$BRANCH; \
			git checkout $$BRANCH; \
		done
	cd cdw-src/; \
		cp ../objects/changes/* $(SFSCHEMA); \
		rm $(SFSCHEMA)/test2.tbl; \
		git add --all; \
		git commit -m 'Changes to myproc and sales table'; \
		git branch -v; \
		git log --oneline --decorate --graph --all; 
	export LOCALBRANCH=${LOCALBRANCH}; cd cdw-src/; \
		for BRANCH in ${BRANCHES} ${MASTERBRANCH} ; do \
			git checkout $$BRANCH; \
			git branch -v; \
			git merge $$LOCALBRANCH -m 'Merge $$LOCALBRANCH to $$BRANCH'; \
			git log --oneline --decorate --graph --all; \
			export LOCALBRANCH=$$BRANCH; \
		done
	@echo Files from the git merge process:
	@find ./branch-output/ -type f

parse-git:
	for DIFF in `ls branch-output/*.diff` ; do \
		./cicd.pl cicd-output/ $$DIFF; \
	done
	@echo Files from the cicd process:
	@find ./cicd-output/ -type f

clean:
	rm -rf branch-output/
	rm -rf cicd-output/
	rm -rf cdw-src/

