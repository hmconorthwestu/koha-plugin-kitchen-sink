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
    name            => 'Weeding and Historical Charges Plugin',
    author          => 'Hannah Co',
    date_authored   => '2020-10-05',
    date_updated    => "1900-01-01",
    minimum_version => '20.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
    description     => 'This plugin creates a custom report of item checkouts '
      . 'that can be narrowed by a variety of parameters.',
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

    unless ( $cgi->param('output') ) {
        $self->inventory_step1();
    }
    else {
      if ( $cgi->param('timerange') & !$cgi->param('ccode') ) {
        $self->inventory_step1();
      } else {
        $self->inventory_step2();
      }
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
  } elsif ( undef($timerange) ) {
    $start_date = $today - DateTime::Duration->new( months => 6 );
  } else {
    $print = "timerange not handled, set to " . $timerange . "<br/>";
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
  WHERE withdrawn != '1'
    AND library = $branch
  GROUP BY ccode
  ORDER BY ccode) xall
  LEFT JOIN (SELECT ccode, COUNT(DISTINCT barcode) complete
  FROM items
  WHERE (datelastseen > $start_date)
    AND withdrawn != '1'
    AND library = $branch
  GROUP BY ccode
  ORDER BY ccode) done
  ON xall.ccode = done.ccode";

  my $sth = $dbh->prepare($query);
 $sth->execute();

 my @results;
 while ( my $row = $sth->fetchrow_hashref() ) {
    $row->{'percent'} = $row->{'complete'}/$row->{'total'}*100;
     push( @results, $row );
 }


  my @libraries = Koha::Libraries->search;
  my @categories = Koha::Patron::Categories->search_limited({}, {order_by => ['description']});
  $template->param(
      print => $print,
      libraries => \@libraries,
      results => \@results,
  );

  $self->output_html( $template->output() );
}


sub report_step2 {
  my ( $self, $args ) = @_;
  my $cgi = $self->{'cgi'};

  my $dbh = C4::Context->dbh;

  my $timerange = $cgi->param('timerange');
  my $branch = $cgi->param('branch');
  my $ccode = $cgi->param('ccode');

  my $barcode   = $cgi->param('bc');

  my $date = dt_from_string();
  $date = output_pref ( { dt => $date, dateformat => 'iso' } );


  my $query = "
	SELECT items.ccode,items.location,items.cn_source,items.cn_sort,items.itemcallnumber AS callnumber,items.enumchron,items.barcode,biblio.title AS title,biblio.author
	FROM items
	LEFT JOIN biblioitems ON (items.biblioitemnumber=biblioitems.biblioitemnumber)
	LEFT JOIN biblio ON (biblioitems.biblionumber=biblio.biblionumber)
  WHERE (items.homebranch = '$branch' AND items.ccode = '$ccode'
  ";

  $query .= ")";

  if ( $timerange eq '6' ) {

  } elsif ( $timerange eq '12' ) {

  }

	$query .= "
	ORDER BY items.cn_source, items.cn_sort ASC
	";

  my $sth = $dbh->prepare($query);
  $sth->execute();

  my @results;
  while ( my $row = $sth->fetchrow_hashref() ) {
      push( @results, $row );
  }

  my $filename;

  my $template = $self->get_template({ file => 'inventory-step2.tt' });

  $template->param(
      date_ran     => dt_from_string(),
      results_loop => \@results,
	    branch       => Koha::Libraries->find($branch)->branchname,
  );

  unless ( $ccode eq '%' ) {
      $template->param( ccode => $ccode );
  }

  $self->output_html( $template->output() );
}

1;