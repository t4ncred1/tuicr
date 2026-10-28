//! The cursor asks whether the comment under it is locked before offering to
//! edit or delete it. The annotation carries an index straight into the
//! line's comment vec — the same index every other cursor lookup uses.

use crate::app::*;
use crate::model::comment::CommentLifecycleState;
use crate::model::{Comment, CommentType, DiffFile, FileStatus, LineSide};
use crate::vcs::traits::VcsType;

struct DummyVcs {
    info: VcsInfo,
}

impl VcsBackend for DummyVcs {
    fn info(&self) -> &VcsInfo {
        &self.info
    }
    fn get_working_tree_diff(&self, _highlighter: &SyntaxHighlighter) -> Result<Vec<DiffFile>> {
        Err(TuicrError::NoChanges)
    }
    fn fetch_context_lines(
        &self,
        _file_path: &Path,
        _file_status: crate::model::FileStatus,
        _ref_commit: Option<&str>,
        _start_line: u32,
        _end_line: u32,
    ) -> Result<Vec<DiffLine>> {
        Ok(Vec::new())
    }
    fn file_line_count(
        &self,
        _file_path: &Path,
        _file_status: crate::model::FileStatus,
        _ref_commit: Option<&str>,
    ) -> Result<u32> {
        Ok(0)
    }
    fn get_change_status(&self) -> Result<VcsChangeStatus> {
        Ok(VcsChangeStatus {
            staged: false,
            unstaged: false,
        })
    }
}

fn diff_file(path: &str) -> DiffFile {
    DiffFile {
        old_path: None,
        new_path: Some(PathBuf::from(path)),
        status: FileStatus::Modified,
        hunks: Vec::new(),
        is_binary: false,
        is_too_large: false,
        is_commit_message: false,
        content_hash: 0,
    }
}

fn comment(side: LineSide, state: CommentLifecycleState) -> Comment {
    let mut comment = Comment::new(
        "a remark".to_string(),
        CommentType::from_id("note"),
        Some(side),
    );
    comment.lifecycle_state = state;
    comment
}

fn build_app() -> App {
    let vcs_info = VcsInfo {
        root_path: PathBuf::from("/tmp"),
        head_commit: "head".to_string(),
        branch_name: Some("main".to_string()),
        vcs_type: VcsType::Git,
    };
    let session = ReviewSession::new(
        vcs_info.root_path.clone(),
        vcs_info.head_commit.clone(),
        vcs_info.branch_name.clone(),
        SessionDiffSource::WorkingTree,
    );
    App::build(
        Box::new(DummyVcs {
            info: vcs_info.clone(),
        }),
        vcs_info,
        Theme::dark(),
        None,
        false,
        vec![diff_file("src/main.rs")],
        session,
        DiffSource::WorkingTree,
        InputMode::Normal,
        Vec::new(),
        None,
        None,
    )
    .expect("failed to build test app")
}

#[test]
fn should_answer_about_the_comment_the_annotation_points_at() {
    // Line 42 holds a comment on each side. The annotation for the new-side
    // box carries index 1 — into the whole vec, the way the builder emits it
    // and every other lookup reads it. Re-counting per side would land on a
    // different comment and call a published one editable.
    let mut app = build_app();
    let path = PathBuf::from("src/main.rs");
    app.session.add_file(path.clone(), FileStatus::Modified, 0);
    let review = app.session.get_file_mut(&path).unwrap();
    review.add_line_comment(42, comment(LineSide::Old, CommentLifecycleState::Submitted));
    review.add_line_comment(42, comment(LineSide::New, CommentLifecycleState::Submitted));

    app.line_annotations = vec![AnnotatedLine::LineComment {
        file_idx: 0,
        line: 42,
        comment_idx: 1,
        side: LineSide::New,
    }];
    app.diff_state.cursor_line = 0;
    app.diff_state.current_file_idx = 0;

    assert!(
        app.cursor_on_locked_comment(),
        "index 1 is the submitted new-side comment; a per-side recount would \
         miss it and offer to edit a comment that is already on the forge"
    );
}

struct TestReviewsDir {
    _dir: tempfile::TempDir,
}

impl TestReviewsDir {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        crate::persistence::storage::set_test_reviews_dir(Some(dir.path().to_path_buf()));
        Self { _dir: dir }
    }
}

impl Drop for TestReviewsDir {
    fn drop(&mut self) {
        crate::persistence::storage::set_test_reviews_dir(None);
    }
}

#[test]
fn should_reply_to_a_submitted_comment_without_editing_it() {
    // Replies are local-only, so a comment already on the forge still takes
    // one, and the comment itself must come through untouched.
    let _reviews = TestReviewsDir::new();
    let mut app = build_app();
    let path = PathBuf::from("src/main.rs");
    app.session.add_file(path.clone(), FileStatus::Modified, 0);
    app.session
        .get_file_mut(&path)
        .unwrap()
        .add_line_comment(42, comment(LineSide::New, CommentLifecycleState::Submitted));
    app.line_annotations = vec![AnnotatedLine::LineComment {
        file_idx: 0,
        line: 42,
        comment_idx: 0,
        side: LineSide::New,
    }];
    app.diff_state.cursor_line = 0;
    app.diff_state.current_file_idx = 0;

    assert!(app.enter_reply_mode());
    assert!(app.comment_buffer.is_empty(), "a reply starts empty");
    app.comment_buffer = "fixed in the next commit".to_string();
    app.save_comment();

    let saved = &app.session.files[&path].line_comments[&42][0];
    assert_eq!(saved.content, "a remark");
    assert_eq!(saved.replies.len(), 1);
    assert_eq!(saved.replies[0].content, "fixed in the next commit");
    assert_eq!(saved.replies[0].author, app.username);
    assert_eq!(app.input_mode, InputMode::Normal);
    assert!(!app.replying_to_comment);
}
