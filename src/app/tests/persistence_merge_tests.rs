use crate::app::*;

const SOME_HASH: u64 = 0xabc;

fn test_session() -> ReviewSession {
    let mut session = ReviewSession::new(
        PathBuf::from("/repo"),
        "abc1234".to_string(),
        Some("main".to_string()),
        SessionDiffSource::WorkingTree,
    );
    session.add_file(
        PathBuf::from("src/main.rs"),
        FileStatus::Modified,
        SOME_HASH,
    );
    session
}

fn comment(id: &str, content: &str) -> Comment {
    let mut comment = Comment::new(content.to_string(), CommentType::from_id("note"), None);
    comment.id = id.to_string();
    comment
}

fn push_file_comment(session: &mut ReviewSession, id: &str, content: &str) {
    session
        .get_file_mut(&PathBuf::from("src/main.rs"))
        .unwrap()
        .file_comments
        .push(comment(id, content));
}

fn file_comment_ids(session: &ReviewSession) -> Vec<String> {
    session
        .files
        .get(&PathBuf::from("src/main.rs"))
        .unwrap()
        .file_comments
        .iter()
        .map(|comment| comment.id.clone())
        .collect()
}

#[test]
fn should_merge_external_comment_without_losing_local_comment() {
    let base = test_session();
    let mut current = base.clone();
    let mut latest = base.clone();

    push_file_comment(&mut current, "local", "from tui");
    push_file_comment(&mut latest, "external", "from cli");

    let changed = App::merge_external_session_changes(&mut current, &base, &latest);

    assert_eq!(changed, 1);
    assert_eq!(file_comment_ids(&current), vec!["local", "external"]);
}

#[test]
fn should_not_resurrect_locally_deleted_comment_when_disk_is_unchanged() {
    let mut base = test_session();
    push_file_comment(&mut base, "deleted", "old");
    let mut current = base.clone();
    current
        .get_file_mut(&PathBuf::from("src/main.rs"))
        .unwrap()
        .file_comments
        .clear();
    let latest = base.clone();

    let changed = App::merge_external_session_changes(&mut current, &base, &latest);

    assert_eq!(changed, 0);
    assert!(file_comment_ids(&current).is_empty());
}

#[test]
fn should_apply_external_edit_when_comment_is_unchanged_locally() {
    let mut base = test_session();
    push_file_comment(&mut base, "same", "old");
    let mut current = base.clone();
    let mut latest = base.clone();
    latest
        .get_file_mut(&PathBuf::from("src/main.rs"))
        .unwrap()
        .file_comments[0]
        .content = "new".to_string();

    let changed = App::merge_external_session_changes(&mut current, &base, &latest);

    assert_eq!(changed, 1);
    assert_eq!(
        current
            .files
            .get(&PathBuf::from("src/main.rs"))
            .unwrap()
            .file_comments[0]
            .content,
        "new"
    );
}

fn push_reply(session: &mut ReviewSession, comment_id: &str, reply_id: &str, content: &str) {
    let review = session.get_file_mut(&PathBuf::from("src/main.rs")).unwrap();
    let comment = review
        .file_comments
        .iter_mut()
        .find(|comment| comment.id == comment_id)
        .unwrap();
    let mut reply = crate::model::CommentReply::new(content.to_string(), "user");
    reply.id = reply_id.to_string();
    comment.replies.push(reply);
}

fn reply_ids(session: &ReviewSession) -> Vec<String> {
    session.files[&PathBuf::from("src/main.rs")].file_comments[0]
        .replies
        .iter()
        .map(|reply| reply.id.clone())
        .collect()
}

#[test]
fn should_keep_both_replies_when_local_and_external_answer_the_same_comment() {
    let mut base = test_session();
    push_file_comment(&mut base, "root", "question");
    let mut current = base.clone();
    let mut latest = base.clone();
    push_reply(&mut current, "root", "local", "from tui");
    push_reply(&mut latest, "root", "agent", "from claude");

    let changed = App::merge_external_session_changes(&mut current, &base, &latest);

    assert_eq!(changed, 1);
    let mut ids = reply_ids(&current);
    ids.sort();
    assert_eq!(ids, vec!["agent", "local"]);
}

#[test]
fn should_keep_external_reply_when_the_comment_was_edited_locally() {
    let mut base = test_session();
    push_file_comment(&mut base, "root", "question");
    let mut current = base.clone();
    let mut latest = base.clone();
    current
        .get_file_mut(&PathBuf::from("src/main.rs"))
        .unwrap()
        .file_comments[0]
        .content = "edited".to_string();
    push_reply(&mut latest, "root", "agent", "from claude");

    App::merge_external_session_changes(&mut current, &base, &latest);

    let comment = &current.files[&PathBuf::from("src/main.rs")].file_comments[0];
    assert_eq!(comment.content, "edited");
    assert_eq!(reply_ids(&current), vec!["agent"]);
}

#[test]
fn should_apply_external_reply_deletion_but_keep_local_ones_deleted() {
    let mut base = test_session();
    push_file_comment(&mut base, "root", "question");
    push_reply(&mut base, "root", "gone-externally", "a");
    push_reply(&mut base, "root", "gone-locally", "b");
    push_reply(&mut base, "root", "kept", "c");
    let mut current = base.clone();
    let mut latest = base.clone();
    current
        .get_file_mut(&PathBuf::from("src/main.rs"))
        .unwrap()
        .file_comments[0]
        .replies
        .retain(|reply| reply.id != "gone-locally");
    latest
        .get_file_mut(&PathBuf::from("src/main.rs"))
        .unwrap()
        .file_comments[0]
        .replies
        .retain(|reply| reply.id != "gone-externally");

    let changed = App::merge_external_session_changes(&mut current, &base, &latest);

    assert_eq!(changed, 1);
    assert_eq!(reply_ids(&current), vec!["kept"]);
}

#[test]
fn should_bring_in_replies_of_a_comment_added_externally() {
    let base = test_session();
    let mut current = base.clone();
    let mut latest = base.clone();
    push_file_comment(&mut latest, "root", "question");
    push_reply(&mut latest, "root", "agent", "answer");

    App::merge_external_session_changes(&mut current, &base, &latest);

    assert_eq!(reply_ids(&current), vec!["agent"]);
}
