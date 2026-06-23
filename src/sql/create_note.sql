INSERT INTO notes (text) values ($1)
RETURNING id, text;
