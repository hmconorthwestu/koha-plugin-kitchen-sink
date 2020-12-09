package Koha::Plugin::Com::NULibrary::Inventory;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

## We will also need to include any Koha libraries we want to access
use C4::Context;
use C4::Auth;
use C4::Koha;
use Koha::DateUtils;
use Koha::Libraries;
#use Koha::Patron::Categories;
use Koha::AuthorisedValues;
#use Koha::Account::Lines;
use MARC::Record;
use Cwd qw(abs_path);
use Mojo::JSON qw(decode_json);;
use URI::Escape qw(uri_unescape);
use LWP::UserAgent;

## Here we set our plugin version
our $VERSION = "{VERSION}";

## Here is our metadata, some keys are required, some are optional
our $metadata = {
    name            => 'Inventory Plugin',
    author          => 'Hannah Co',
    date_authored   => '2020-10-05',
    date_updated    => "1900-01-01",
    minimum_version => '20.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin tracks inventory progress over time '
      . 'and provides lists of items not scanned.',
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;

    ## We need to add our metadata here so our base class can access it
    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    ## Here, we call the 'new' method for our base class
    ## This runs some additional magic and checking
    ## and returns our actual $self
    my $self = $class->SUPER::new($args);

    return $self;
}

## The existance of a 'report' subroutine means the plugin is capable
## of running a report. This example report can output a list of patrons
## either as HTML or as a CSV file. Technically, you could put all your code
## in the report method, but that would be a really poor way to write code
## for all but the simplest reports
sub report {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

      if ( $cgi->param('ccode') ) {
        if ( $cgi->param('cn') ) {
          $self->inventory_step3();
        } else {
          $self->inventory_step2();
        }
      } else {
        $self->inventory_step1();
      }

}

## If your plugin needs to add some CSS to the staff intranet, you'll want
## to return that CSS here. Don't forget to wrap your CSS in <style>
## tags. By not adding them automatically for you, you'll have a chance
## to include external CSS files as well!
sub intranet_head {
    my ( $self ) = @_;

    return q|
        <style>
          body {
            background-color: orange;
          }
        </style>
    |;
}

## If your plugin needs to add some javascript in the staff intranet, you'll want
## to return that javascript here. Don't forget to wrap your javascript in
## <script> tags. By not adding them automatically for you, you'll have a
## chance to include other javascript files if necessary.
sub intranet_js {
    my ( $self ) = @_;

    return q|
        <script>console.log("Thanks for testing the kitchen sink plugin!");</script>
    |;
}

## This method allows you to add new html elements to the catalogue toolbar.
## You'll want to return a string of raw html here, most likely a button or other
## toolbar element of some form. See bug 20968 for more details.
sub intranet_catalog_biblio_enhancements_toolbar_button {
    my ( $self ) = @_;

    return q|
        <a class="btn btn-default btn-sm" onclick="alert('Peace and long life');">
          <i class="fa fa-hand-spock-o" aria-hidden="true"></i>
          Live long and prosper
        </a>
    |;
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('mytable');

    return C4::Context->dbh->do( "
        CREATE TABLE IF NOT EXISTS $table (
            `borrowernumber` INT( 11 ) NOT NULL
        ) ENGINE = INNODB;
    " );
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    my $table = $self->get_qualified_table_name('mytable');

    return C4::Context->dbh->do("DROP TABLE IF EXISTS $table");
}

## These are helper functions that are specific to this plugin
## You can manage the control flow of your plugin any
## way you wish, but I find this is a good approach

sub inventory_step1 {
  my ( $self, $args ) = @_;
  my $cgi = $self->{'cgi'};

  my $print;

  my $today = DateTime->now;
  my $start_date;

  my $timerange = $cgi->param('timerange');

  if ( $timerange ) {
    $start_date = $today - DateTime::Duration->new( months => $timerange );
#    $print .= "timerange is " . $timerange . ", using date " . $start_date . "<br/>";
  } else {
    $start_date = $today - DateTime::Duration->new( months => 6 );
#    $print .= "timerange not set, using date " . $start_date . "<br/>";
  }

  my $branch = $cgi->param('branch');

  unless ( $branch ) {
    $branch = "KIRKLAND";
  }

  my $dbh = C4::Context->dbh;

  my $template = $self->get_template({ file => 'inventory-step1.tt' });

  my $query = "SELECT xall.ccode, complete, total FROM
  (SELECT ccode, COUNT(DISTINCT barcode) total
  FROM items
  WHERE withdrawn <> '1'
    AND homebranch = 'KIRKLAND'
  GROUP BY ccode
  ORDER BY ccode) xall
  LEFT JOIN (SELECT ccode, COUNT(DISTINCT barcode) complete
  FROM items
  WHERE (datelastseen > '2020-10-01')
    AND withdrawn <> '1'
    AND homebranch = 'KIRKLAND'
  GROUP BY ccode
  ORDER BY ccode) done
  ON xall.ccode = done.ccode";

  my $sth = $dbh->prepare($query);
 $sth->execute();

 my @results;
 while ( my $r = $sth->fetchrow_hashref() ) {
   my $row;
    my $percent = $r->{'complete'}/$r->{'total'}*100;
    $row->{'percent'} = int $percent;
    $row->{'ccode'} = $r->{'ccode'};
     push( @results, $row );
 }
my @libraries = Koha::Libraries->search;

  $template->param(
      print => $print,
      libraries => \@libraries,
      timerange => $timerange,
      branch => $branch,
      results => \@results,
  );

  $self->output_html( $template->output() );
}

sub inventory_step2 {
  my ( $self, $args ) = @_;
  my $cgi = $self->{'cgi'};

  my $dbh = C4::Context->dbh;

  my $timerange = $cgi->param('timerange');
  my $branch = $cgi->param('branch');
  my $ccode = $cgi->param('ccode');

  my $print;

  my $today = DateTime->now;
  my $start_date;

  if ( $timerange ) {
    $start_date = $today - DateTime::Duration->new( months => $timerange );
  #  $print .= "timerange is " . $timerange . ", using date " . $start_date . "<br/>";
  } else {
    $start_date = $today - DateTime::Duration->new( months => 6 );
  #  $print .= "timerange not set, using date " . $start_date . "<br/>";
  }

  my $branch = $cgi->param('branch');

  unless ( $branch ) {
    $branch = "KIRKLAND";
  }

  my $query = "SELECT xall.ccode, xall.cn, complete, total FROM
				(SELECT ccode, cn_source, SUBSTRING_INDEX( itemcallnumber, ' ', 1 ) cn, COUNT(DISTINCT barcode) total
				FROM items
				WHERE withdrawn <> '1'
					AND ccode = '$ccode'
					AND homebranch = '$branch'
				GROUP BY ccode, cn
				ORDER BY cn_source, ccode, cn) xall
			LEFT JOIN
				(SELECT ccode, cn_source, SUBSTRING_INDEX( itemcallnumber, ' ', 1 ) cn, COUNT(DISTINCT barcode) complete
				FROM items
				WHERE (datelastseen > '$start_date')
					AND ccode = '$ccode'
					AND withdrawn <> '1'
					AND homebranch = '$branch'
				GROUP BY ccode, cn
				ORDER BY cn_source, ccode, cn) done
			ON (xall.ccode = done.ccode)
				AND (xall.cn = done.cn)";

  my $sth = $dbh->prepare($query);
  $sth->execute();

  my @results;
  while ( my $r = $sth->fetchrow_hashref() ) {
    my $row;
     my $percent = $r->{'complete'}/$r->{'total'}*100;
     $row->{'percent'} = int $percent;
     $row->{'cn_source'} = $r->{'cn_source'};
     $row->{'ccode'} = $r->{'ccode'};
     $row->{'cn'} = $r->{'cn'};
      push( @results, $row );
  }

  my $filename;

  my $template = $self->get_template({ file => 'inventory-step2.tt' });

  $template->param(
      print => $print,
      timerange => $timerange,
      branch => $branch,
      results => \@results,
  );

  unless ( $ccode eq '%' ) {
      $template->param( ccode => $ccode );
  }

  $self->output_html( $template->output() );
}

sub inventory_step3 {
  my ( $self, $args ) = @_;
  my $cgi = $self->{'cgi'};

  my $dbh = C4::Context->dbh;

  my $timerange = $cgi->param('timerange');
  my $branch = $cgi->param('branch');
  my $ccode = $cgi->param('ccode');
  my $cn = $cgi->param('cn');
  my $bc = $cgi->param('bc');
  my $mbc = $cgi->param('mbc');
  my $mark_missing = $cgi->param('mark_missing');

  my $print;

  my $today = DateTime->now;
  my $start_date;

  if ( $timerange ) {
    $start_date = $today - DateTime::Duration->new( months => $timerange );
#    $print .= "timerange is " . $timerange . ", using date " . $start_date . "<br/>";
  } else {
    $start_date = $today - DateTime::Duration->new( months => 6 );
#    $print .= "timerange not set, using date " . $start_date . "<br/>";
  }

# if item scanned, mark as seen
if ( $bc ) {
  my $dt = dt_from_string();
  	my $datelastseen = $dt->ymd('-');
  	my $kohaitem = Koha::Items->find({barcode => $bc});
    my $item;
  	if ( $kohaitem ) {
  		my $item = $kohaitem->unblessed;
        # Modify date last seen for scanned items, remove lost status
        $kohaitem->set({ itemlost => 0, datelastseen => $datelastseen })->store;
        # update item hash accordingly
      }
    }

if ( $mark_missing eq "TRUE" ) {
  	my $kohaitem = Koha::Items->find({barcode => $mbc});
  	if ( $kohaitem ) {
        # Modify itemlost status to 3 = missing
        $kohaitem->set({ itemlost => 3 })->store;
        # update item hash accordingly
      }
    }

  if ($cgi->param('ccode')) {
#    $print .= "param ccode is set as " . $cgi->param('ccode');
  }

  # $print .= "param cn is set as " . $cgi->param('cn');

  my $branch = $cgi->param('branch');

  unless ( $branch ) {
    $branch = "KIRKLAND";
  }

  my $query = "SELECT i.barcode, i.itemcallnumber, i.homebranch, i.holdingbranch, i.ccode, i.location, i.enumchron, i.datelastseen, b.title, b.author, i.itemlost, i.onloan
				FROM items i
					LEFT JOIN biblio b ON (i.biblionumber = b.biblionumber)
				WHERE (i.datelastseen < '$start_date')
					AND i.ccode = '$ccode'
					AND i.withdrawn <> '1'
					AND i.homebranch = '$branch'
					AND i.itemcallnumber LIKE '$cn %'
				ORDER BY i.itemcallnumber
			LIMIT 5000";

  my $sth = $dbh->prepare($query);
  $sth->execute();

  my @results;
  while ( my $row = $sth->fetchrow_hashref() ) {
    push( @results, $row );
  }

  my $filename;

  my $template = $self->get_template({ file => 'inventory-step3.tt' });

  $template->param(
      print => $print,
      timerange => $timerange,
      branch => $branch,
      results => \@results,
  );

  unless ( $ccode eq '%' ) {
      $template->param( ccode => $ccode );
  }

  $self->output_html( $template->output() );
}

1;
