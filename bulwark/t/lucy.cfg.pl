{
	SETTINGS => {
		MACHINE_NAME => 'lucy.connectingup.org',
		MAILTO => [qw/all@nws.hu/],
	},
	DEFAULTS => {
		DB => {
			USER => 'root',
			PASS => '',
		},
		DIR => {
			EXCLUDE => [qw/.git .svn DEADJOE *.swp/],
		},
		GPG => {
			MODE => 'pass',
			PASS => 'dfdas',
		},
	},
	TO => {
		local => {
			DIR => '/backups/store',
			KEEP => 1,
		},
		s3 => {
			BUCKET => 'cua-backup-au',
			KEEP => 10,
			CFG => '/backups/s3.cfg',
		},
		s3_nz => {
			BUCKET => 'cua-backup-nz',
			KEEP => 10,
			CFG => '/backups/s3.cfg',
		},
	},
	BACKUPS => {
		cua => { # this will produce BACKUPROOT/cua/DATE/cua_webroot.tgz and BACKUPROOT/cua/DATE/cua_db.sql.gz
			FROM => {
				webroot => {
					DIR => '/var/www/prod_cua/',
					EXCLUDE => ['sites/default/files/event-membership.log'],
				},
				db => {
					DB => [qw/prod_cua prod_donortec/],
				},
			},
			TO => [qw/local s3/],
		},
		sacomm => {
			FROM => {
				db => {
					DB => [qw/prod_sacommunity/],
				},
				webroot => {
					DIR => '/var/www/prod_sacommunity',
					EXCLUDE => ['cache/*'],
				},
			},
			TO => [qw/s3 s3_nz/],
		},
	},
}
