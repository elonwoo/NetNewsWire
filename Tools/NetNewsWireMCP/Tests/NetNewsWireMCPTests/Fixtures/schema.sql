CREATE TABLE articles (
    articleID TEXT NOT NULL PRIMARY KEY,
    feedID TEXT NOT NULL,
    uniqueID TEXT NOT NULL,
    title TEXT,
    contentHTML TEXT,
    contentText TEXT,
    markdown TEXT,
    url TEXT,
    externalURL TEXT,
    summary TEXT,
    imageURL TEXT,
    bannerImageURL TEXT,
    datePublished DATE,
    dateModified DATE,
    searchRowID INTEGER,
    authors TEXT,
    attachments TEXT,
    thumbnailURL TEXT
);

CREATE TABLE statuses (
    articleID TEXT NOT NULL PRIMARY KEY,
    read BOOL NOT NULL DEFAULT 0,
    starred BOOL NOT NULL DEFAULT 0,
    dateArrived DATE NOT NULL DEFAULT 0
);

CREATE VIRTUAL TABLE search USING fts4(title, body);

CREATE TRIGGER articles_after_delete_trigger_delete_search_text
AFTER DELETE ON articles
BEGIN
    DELETE FROM search WHERE rowid = OLD.searchRowID;
END;

CREATE INDEX articles_feedID_datePublished_articleID
ON articles (feedID, datePublished, articleID);

CREATE TABLE feedSettings (
    feedURL TEXT PRIMARY KEY,
    feedID TEXT NOT NULL DEFAULT '',
    homePageURL TEXT,
    iconURL TEXT,
    faviconURL TEXT,
    editedName TEXT,
    contentHash TEXT,
    newArticleNotificationsEnabled INTEGER NOT NULL DEFAULT 0,
    readerViewAlwaysEnabled INTEGER NOT NULL DEFAULT 0,
    authors TEXT,
    externalID TEXT,
    folderRelationship TEXT,
    lastCheckDate REAL,
    lastResponseCode INTEGER
);
