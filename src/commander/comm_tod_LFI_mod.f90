module comm_tod_LFI_mod
  use comm_tod_mod
  use comm_param_mod
  use comm_map_mod
  implicit none

  private
  public comm_LFI_tod

  type, extends(comm_tod) :: comm_LFI_tod 
   contains
     procedure     :: process_tod        => process_LFI_tod
     procedure     :: compute_binned_map
     procedure     :: sample_gain
     procedure     :: sample_n_corr
     procedure     :: compute_cleaned_tod
     procedure     :: construct_sl_template
  end type comm_LFI_tod

  interface comm_LFI_tod
     procedure constructor
  end interface comm_LFI_tod

contains

  !**************************************************
  !             Constructor
  !**************************************************
  function constructor(cpar)
    implicit none
    type(comm_params),       intent(in) :: cpar
    class(comm_LFI_tod),     pointer    :: constructor

    ! Set up LFI specific parameters
    allocate(constructor)
    constructor%myid     = cpar%myid
    constructor%numprocs = cpar%numprocs

    ! Test code, just to be able to read a single file; need to settle on parameter structure
    call constructor%get_scan_ids("data/filelist_5files.txt")

    constructor%nmaps    = 3
    constructor%ndet     = 4
    constructor%nhorn    = 1
    constructor%samprate = 50.d0
    allocate(constructor%stokes(constructor%nmaps))
    allocate(constructor%w(constructor%nmaps,constructor%nhorn,constructor%ndet))
    constructor%stokes = [1,2,3]
    constructor%w      = 1.d0

    ! Read the actual TOD
    call constructor%read_tod

  end function constructor

  !**************************************************
  !             Driver routine
  !**************************************************
  subroutine process_LFI_tod(self, map_in, map_out, rms_out)
    implicit none
    class(comm_LFI_tod),               intent(in)    :: self
    type(map_ptr),       dimension(:), intent(in)    :: map_in            ! One map per detector
    class(comm_map),                   intent(inout) :: map_out, rms_out ! Combined output map and rms

    integer(i4b) :: i, j, ntod, ndet, nside, npix, nmaps
    real(dp)     :: t1, t2
    real(sp), allocatable, dimension(:,:)   :: n_corr, s_sl, d_calib, s_sky, s_orb
    real(dp), allocatable, dimension(:,:)   :: map_tot, rms_tot
    real(dp), allocatable, dimension(:,:,:) :: map_sky
    real(dp), allocatable, dimension(:)     :: A_abscal, b_abscal

    ! Set up full-sky map structures
    nside = map_out%info%nside
    nmaps = map_out%info%nmaps
    npix  = 12*nside**2
    allocate(map_tot(0:npix-1,nmaps), rms_tot(0:npix-1,nmaps))
    allocate(A_abscal(self%ndet), b_abscal(self%ndet))
    allocate(map_sky(0:npix-1,nmaps,ndet))
    do i = 1, self%ndet
       call map_in(i)%p%bcast_fullsky_map(map_sky(:,:,i))
    end do

    ! Compute output map and rms
    map_tot  = 0.d0
    rms_tot = 0.d0
    !A_abscal = 0.d0
    !b_abscal = 0.d0
    do i = 1, self%nscan

       ! Short-cuts to local variables
       ntod = self%scans(i)%ntod
       ndet = self%ndet

       ! Set up local data structure for current scan
       allocate(d_calib(ntod, ndet))            ! Calibrated and cleaned TOD in uKcmb
       allocate(n_corr(ntod, ndet))             ! Correlated noise in V
       allocate(s_sl(ntod, ndet))               ! Sidelobe in uKcmb
       allocate(s_sky(ntod, ndet))              ! Stationary sky signal in uKcmb
       allocate(s_orb(ntod, ndet))              ! Orbital dipole in uKcmb

       ! --------------------
       ! Analyze current scan
       ! --------------------

       ! Construct sky signal template -- Maksym -- this week

       ! Construct orbital dipole template -- Kristian -- this week-ish

       ! Construct sidelobe template -- Mathew -- long term
       call self%construct_sl_template()
       ! Fit correlated noise -- Haavard -- this week-ish

       ! Fit gain for current scan -- Eirik -- this week

       ! .. Compute contribution to absolute calibration from current scan .. -- let's see

       ! Compute bandpass corrections, as in s_sky(i) - <s_sky> -- Trygve, after deadline

       ! Compute clean and calibrated TOD -- Mathew -- this week
       call self%compute_cleaned_tod(ntod, i, s_orb, s_sl, n_corr, d_calib)

       ! Compute binned map from cleaned TOD -- Marie -- this week
       
       ! Clean up
       deallocate(n_corr, s_sl, s_sky, s_orb, d_calib)

    end do

    ! Compute absolute calibration, summed over all scans, and rescale output maps

    ! Solve combined map, summed over all pixels -- Marie -- weeks

    ! Copy rescaled maps to final output structure
    !map_out%map  = map_tot(map_out%info%pix,:)
    !rms_out%map = rms_tot(rms_out%info%pix,:)

    deallocate(map_tot, rms_tot, map_sky)

  end subroutine process_LFI_tod


  !**************************************************
  !             Sub-process routines
  !**************************************************
  ! Compute map with white noise assumption from correlated noise 
  ! corrected and calibrated data, d' = (d-n_corr-n_temp)/gain 
  subroutine compute_orbital_dipole(self, ind, s_orb)
    implicit none
    class(comm_LFI_tod),                 intent(in)  :: self
    integer(i4b),                        intent(in)  :: ind !scan nr/index
    real(sp),            dimension(:,:), intent(out) :: s_orb
    real(dp)             :: x, T_0, q, pix_dir(3), b, b_dot
    real(dp), parameter  :: h = 6.62607015d-34   ! Planck's constant [Js]
    integer(i4b)         :: i,j

    !T_0 = T_CMB*k_b/h !T_0 = T_CMB frequency
    !x = freq * 1.d9 / (2.d0*T_0) !freq is the center bandpass frequancy of the detector
    !q = x * (exp(2.d0*x)+1) / (exp(2.d0*x)-1) !frequency dependency of the quadrupole
    !b = sqrt(sum(self%scans(ind)%v_sun**2))/c !beta for the given scan

    do i = 1,self%ndet
       do j=1,self%scans(ind)%ntod !length of the tod
          call pix2vec_ring(self%scans(ind)%d(i)%nside, self%scans(ind)%d(i)%pix(j), &
               & pix_dir)
          b_dot = dot_product(self%scans(ind)%v_sun, pix_dir)/c
          s_orb(j,i) = T_CMB * b_dot !only dipole
          !s_orb(j,i) = T_CMB * (b_dot + q*b_dot**2) ! with quadrupole
          !s_orb(j,i) = T_CMB * (b_dot + q*((b_dot**2) - (1.d0/3.d0)*(b**2))) ! net zero monopole
       end do
   end do

  end subroutine compute_orbital_dipole

  ! Compute map with white noise assumption from correlated noise 
  ! corrected and calibrated data, d' = (d-n_corr-n_temp)/gain 
  subroutine compute_binned_map(self, map, rms)
    implicit none
    class(comm_LFI_tod),                 intent(in)  :: self
    real(dp),            dimension(:,:), intent(out) :: map, rms

    map = 0.d0
    rms = 0.d0

  end subroutine compute_binned_map
  
  ! Compute gain as g = (d-n_corr-n_temp)/(map + dipole_orb), where map contains an 
  ! estimate of the stationary sky
  subroutine sample_gain(self, det, n_corr, s_sky, s_sl, s_orb)
    implicit none
    class(comm_LFI_tod),               intent(inout)  :: self
    integer(i4b),                      intent(in)     :: det
    real(sp),            dimension(:), intent(in)     :: n_corr, s_sky, s_sl, s_orb


  end subroutine sample_gain

  ! Compute correlated noise term, n_corr
  subroutine sample_n_corr(self, det, s_sky, s_sl, s_orb, n_corr)
    implicit none
    class(comm_LFI_tod),               intent(in)     :: self
    integer(i4b),                      intent(in)     :: det
    real(sp),            dimension(:), intent(in)     :: s_sky, s_sl, s_orb
    real(sp),            dimension(:), intent(out)    :: n_corr
    
    n_corr = 0.d0

  end subroutine sample_n_corr

  !construct a sidelobe template in the time domain
  subroutine construct_sl_template(self)
    implicit none
    class(comm_LFI_tod),               intent(in)    :: self

  end subroutine construct_sl_template

  !compute the cleaned TOD from the computed TOD components
  subroutine compute_cleaned_tod(self, ntod, scan_num, s_orb, s_sl, n_corr, d_calib)
    implicit none
    class(comm_LFI_tod),               intent(in)    :: self
    integer(i4b),                      intent(in)    :: ntod, scan_num
    real(sp),          dimension(:,:), intent(in)    :: n_corr, s_sl, s_orb
    real(sp),          dimension(:,:), intent(out)   :: d_calib

    integer(i4b) :: i

    !cleaned calibrated data = (rawTOD - orbitalDipole - corrNoise - sidelobes)/gain
    do i=1, self%ndet
      d_calib(:,i) = (self%scans(scan_num)%d(i)%tod - s_orb(:,i) - n_corr(:,i) - s_sl(:,i))/ self%scans(scan_num)%d(i)%gain
    end do
  end subroutine compute_cleaned_tod

end module comm_tod_LFI_mod
