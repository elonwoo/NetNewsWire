INSERT INTO feedSettings (feedURL, feedID, editedName, homePageURL, folderRelationship) VALUES
    ('https://a.example/feed', 'https://a.example/feed', 'Alpha Edited', 'https://a.example/', NULL),
    ('https://b.example/feed', 'https://b.example/feed', NULL, NULL, NULL),
    ('https://c.example/feed', 'https://c.example/feed', '', '', NULL),
    ('https://d.example/feed', 'https://d.example/feed', 'Delta', 'https://d.example/', NULL);

INSERT INTO articles
    (articleID, feedID, uniqueID, title, url, externalURL, datePublished, dateModified, searchRowID, contentText, contentHTML, authors)
VALUES
    ('a1', 'https://a.example/feed', 'a1', 'A one', 'https://a.example/1', NULL, 1700000200, 1700000200, 1, '', '<p>a1</p>', '[{"name":"Author A"}]'),
    ('a2', 'https://a.example/feed', 'a2', 'A two', NULL, 'https://external.example/a2', 1699999999.5, 1700000000, 2, '', '<p>a2</p>', '[]'),
    ('a3', 'https://a.example/feed', 'a3', '', NULL, NULL, NULL, NULL, 3, '', '', NULL),
    ('b1', 'https://b.example/feed', 'b1', 'B one', 'https://b.example/1', NULL, 1700000300, 1700000300, 4, '', '<p>b1</p>', NULL),
    ('b2', 'https://b.example/feed', 'b2', 'B two', NULL, NULL, 1700000050, 1700000050, 5, '', '<p>b2</p>', NULL),
    ('c1', 'https://c.example/feed', 'c1', 'C one', NULL, NULL, 1700000150, 1700000150, 6, '', '<p>c1</p>', NULL);

INSERT INTO statuses (articleID, read, starred, dateArrived) VALUES
    ('a1', 0, 1, 1700000200),
    ('a2', 1, 0, 1700000100),
    ('a3', 0, 0, 1700000000),
    ('b1', 1, 1, 1700000300),
    ('b2', 1, 0, 1700000050);
