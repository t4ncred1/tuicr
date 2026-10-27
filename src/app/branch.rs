//! `--branch` review: every commit the current branch made since it forked,
//! plus uncommitted changes, in one session keyed by the branch.
//!
//! At runtime the review is an ordinary `StagedUnstagedAndCommits` source (or
//! `StagedAndUnstaged` while the branch has no commits of its own). What makes
//! it a branch review is `App::branch_review`: every reload resolves the
//! commit list again, so commits made after tuicr opened join the review, and
//! the session never changes because its slug carries no commit.

use super::diff_load::CommitSelectionAnchor;
use super::*;
use crate::process::run_command_output;

/// Branches a feature branch is assumed to fork from, locally and on every
/// remote, when `--branch` names no base.
const DEFAULT_BASE_BRANCHES: &[&str] = &["main", "master"];

/// State of a `--branch` review.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BranchReview {
    /// The branch `--branch=<base>` named as the fork source. `None` finds the
    /// fork point among `DEFAULT_BASE_BRANCHES`.
    pub base: Option<String>,
}

impl App {
    /// The branch's own commits, oldest first. Empty while the branch has no
    /// commits of its own.
    pub(in crate::app) fn resolve_branch_commits(
        vcs: &dyn VcsBackend,
        root: &Path,
        base: Option<&str>,
    ) -> Result<Vec<String>> {
        if vcs.info().vcs_type != VcsType::Git {
            return Err(TuicrError::UnsupportedOperation(
                "--branch needs a Git repository".into(),
            ));
        }
        let fork_point = branch_fork_point(root, base)?;
        if fork_point == git(root, &["rev-parse", "HEAD"])? {
            return Ok(Vec::new());
        }
        let range = vcs.resolve_revision_range(&format!("{fork_point}..HEAD"))?;
        Ok(range.commit_ids.into_owned())
    }

    /// Points the review at `commit_ids` (oldest first): the diff source, and
    /// a commit pane listing the commits newest-first under the staged and
    /// unstaged rows. A selection narrowed to commits that still exist
    /// survives; anything else selects the whole branch again.
    pub(in crate::app) fn install_branch_commits(&mut self, commit_ids: Vec<String>) -> Result<()> {
        let mut rows = Vec::new();
        if !commit_ids.is_empty() {
            let status = Self::get_change_status_with_ignore(
                self.vcs.as_ref(),
                &self.vcs_info.root_path,
                self.theme.syntax_highlighter(),
                self.path_filter.as_deref(),
            )?;
            if status.staged {
                rows.push(Self::staged_commit_entry());
            }
            if status.unstaged {
                rows.push(Self::unstaged_commit_entry());
            }
            rows.extend(self.vcs.get_commits_info(&commit_ids)?.into_iter().rev());
        }

        let range = match Self::reanchored_commit_selection(
            self.commit_selection_range,
            &self.review_commits,
            &rows,
        ) {
            CommitSelectionAnchor::Moved(range) => range,
            CommitSelectionAnchor::Lost => rows.len().checked_sub(1).map(|last| (0, last)),
        };

        self.diff_source = if commit_ids.is_empty() {
            DiffSource::StagedAndUnstaged
        } else {
            DiffSource::StagedUnstagedAndCommits(commit_ids)
        };
        self.install_refreshed_commit_pane(rows, range);
        self.has_more_commit = false;
        self.show_commit_selector = self.review_commits.len() > 1;
        // The cached whole-range diff is for the old commit list.
        self.range_diff_files = None;
        Ok(())
    }

    /// Resolves the branch's commits again before a reload, so commits made
    /// since the last one join the review. A no-op outside branch reviews and
    /// when the commit list has not changed.
    pub(in crate::app) fn refresh_branch_commits(&mut self) -> Result<()> {
        let Some(branch) = &self.branch_review else {
            return Ok(());
        };
        let commit_ids = Self::resolve_branch_commits(
            self.vcs.as_ref(),
            &self.vcs_info.root_path,
            branch.base.as_deref(),
        )?;
        let unchanged = match &self.diff_source {
            DiffSource::StagedUnstagedAndCommits(current) => *current == commit_ids,
            DiffSource::StagedAndUnstaged => commit_ids.is_empty(),
            _ => false,
        };
        if unchanged {
            return Ok(());
        }
        self.install_branch_commits(commit_ids)
    }
}

/// Where the current branch forked: the merge base with `base` when one was
/// named, otherwise the merge base closest to HEAD among the default base
/// branches. A base that already contains HEAD (the branch is `main` itself,
/// or was merged into it) has no commits to offer and is skipped; when every
/// base does that, the fork point is HEAD and only uncommitted changes show.
fn branch_fork_point(root: &Path, base: Option<&str>) -> Result<String> {
    if let Some(base) = base {
        return git(root, &["merge-base", "HEAD", base]).map_err(|e| {
            TuicrError::InvalidInput(format!("cannot find where HEAD forked from {base}: {e}"))
        });
    }

    let patterns: Vec<String> = DEFAULT_BASE_BRANCHES
        .iter()
        .flat_map(|name| {
            [
                format!("refs/heads/{name}"),
                format!("refs/remotes/*/{name}"),
            ]
        })
        .collect();
    let mut args = vec!["for-each-ref", "--format=%(refname)"];
    args.extend(patterns.iter().map(String::as_str));
    let refs = git(root, &args)?;
    if refs.is_empty() {
        return Err(TuicrError::InvalidInput(format!(
            "no {} branch to find the fork point from; pass --branch=<base>",
            DEFAULT_BASE_BRANCHES.join(" or ")
        )));
    }

    let mut nearest: Option<(u64, String)> = None;
    for base_ref in refs.lines() {
        let Ok(merge_base) = git(root, &["merge-base", "HEAD", base_ref]) else {
            continue;
        };
        let own_commits: u64 = git(
            root,
            &["rev-list", "--count", &format!("{merge_base}..HEAD")],
        )?
        .parse()
        .map_err(|e| TuicrError::VcsCommand(format!("git rev-list --count: {e}")))?;
        if own_commits > 0 && nearest.as_ref().is_none_or(|(best, _)| own_commits < *best) {
            nearest = Some((own_commits, merge_base));
        }
    }
    match nearest {
        Some((_, merge_base)) => Ok(merge_base),
        None => git(root, &["rev-parse", "HEAD"]),
    }
}

fn git(root: &Path, args: &[&str]) -> Result<String> {
    run_command_output("git", Some(root), args)
        .map(|stdout| stdout.trim().to_string())
        .map_err(|e| TuicrError::VcsCommand(format!("git {}: {}", args.join(" "), e.stderr.trim())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    struct Repo(tempfile::TempDir);

    impl Repo {
        fn new() -> Self {
            let repo = Repo(tempfile::tempdir().expect("tempdir"));
            repo.git(&["init", "-q", "-b", "main"]);
            repo.commit("base");
            repo
        }

        fn path(&self) -> &Path {
            self.0.path()
        }

        fn git(&self, args: &[&str]) -> String {
            let output = Command::new("git")
                .args([
                    "-c",
                    "user.name=t",
                    "-c",
                    "user.email=t@t",
                    "-c",
                    "commit.gpgsign=false",
                ])
                .args(args)
                .current_dir(self.path())
                .output()
                .expect("run git");
            assert!(output.status.success(), "git {args:?}: {output:?}");
            String::from_utf8(output.stdout).unwrap().trim().to_string()
        }

        /// Commits a new file named after the message; returns its id.
        fn commit(&self, message: &str) -> String {
            std::fs::write(self.path().join(format!("{message}.txt")), message).unwrap();
            self.git(&["add", "."]);
            self.git(&["commit", "-q", "-m", message]);
            self.git(&["rev-parse", "HEAD"])
        }
    }

    #[test]
    fn should_fork_from_the_point_the_branch_left_main() {
        // given a branch that left main, after which main moved on
        let repo = Repo::new();
        let fork = repo.commit("on-main");
        repo.git(&["checkout", "-q", "-b", "feature"]);
        repo.commit("feature-1");
        repo.git(&["checkout", "-q", "main"]);
        repo.commit("main-later");
        repo.git(&["checkout", "-q", "feature"]);

        // when / then
        assert_eq!(branch_fork_point(repo.path(), None).unwrap(), fork);
    }

    #[test]
    fn should_prefer_the_base_nearest_to_head() {
        // given a stale local master and a remote-tracking main the branch
        // forked from later
        let repo = Repo::new();
        repo.git(&["branch", "master"]);
        let fork = repo.commit("upstream-work");
        repo.git(&["update-ref", "refs/remotes/upstream/main", "HEAD"]);
        repo.git(&["checkout", "-q", "-b", "feature"]);
        repo.commit("feature-1");
        repo.git(&["branch", "-q", "-f", "main", "master"]);

        // when / then: master would also pull in upstream-work
        assert_eq!(branch_fork_point(repo.path(), None).unwrap(), fork);
    }

    #[test]
    fn should_have_no_own_commits_on_the_base_branch_itself() {
        let repo = Repo::new();
        let head = repo.commit("on-main");

        assert_eq!(branch_fork_point(repo.path(), None).unwrap(), head);
    }

    #[test]
    fn should_fork_from_an_explicit_base() {
        // given a branch stacked on another feature branch
        let repo = Repo::new();
        repo.git(&["checkout", "-q", "-b", "parent"]);
        let fork = repo.commit("parent-1");
        repo.git(&["checkout", "-q", "-b", "child"]);
        repo.commit("child-1");

        // when / then
        assert_eq!(
            branch_fork_point(repo.path(), Some("parent")).unwrap(),
            fork
        );
    }

    #[test]
    fn should_ask_for_a_base_when_there_is_no_main_or_master() {
        let repo = Repo::new();
        repo.git(&["branch", "-q", "-m", "main", "develop"]);

        let error = branch_fork_point(repo.path(), None).unwrap_err();

        assert!(error.to_string().contains("--branch=<base>"), "{error}");
    }
}
