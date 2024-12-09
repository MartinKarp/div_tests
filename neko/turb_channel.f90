! Martin Karp 13/3-2023
! updated initial condition Philipp Schlatter 09/07/2024
module user
  use neko
  implicit none

contains

  ! Register user defined functions (see user_intf.f90)
  subroutine user_setup(u)
    type(user_t), intent(inout) :: u
    u%fluid_user_ic => user_ic
    u%user_mesh_setup => user_mesh_scale
    u%user_check => user_calc_quantities
  end subroutine user_setup
 
  ! User-defined routine called at the end of every time step
  subroutine user_calc_quantities(t, tstep, u, v, w, p, coef, params)
    real(kind=rp), intent(in) :: t
    integer, intent(in) :: tstep
    type(coef_t), intent(inout) :: coef
    type(json_file), intent(inout) :: params
    type(field_t), intent(inout) :: u
    type(field_t), intent(inout) :: v
    type(field_t), intent(inout) :: w
    type(field_t), intent(inout) :: p
    type(field_t), pointer :: d_x, d_y, d_z, work
    integer :: ntot, i, j, id
    real(kind=rp) ::  el_val


    d_x => neko_field_registry%get_field("du_dx")
    d_y => neko_field_registry%get_field("dv_dy")
    d_z => neko_field_registry%get_field("dw_dz")
    id = 0
    call neko_scratch_registry%request_field(work, id)
    ntot = u%dof%size()

    call add4(work%x, d_x%x, d_y%x, d_z%x,ntot)
    !call copy(d_x%x,work%x,ntot)
   
    do i = 1, u%msh%nelv
       el_val = 0.0
       do j = 1, u%Xh%lxyz
          el_val = el_val + work%x(j,1,1,i)*coef%B(j,1,1,i)
       end do
       do j = 1, u%Xh%lxyz
 !         d_y%x(j,1,1,i) = el_val
       end do
    end do
     
    el_val = glsc2(work%x,coef%B,ntot)
    el_val = sqrt(glsc3(work%x,work%x,coef%B,ntot))
  !  call col3(d_z%x, work%x,coef%B, ntot)
    print *,'divergence big',el_val
    el_val = sqrt(glsc2(work%x,work%x,ntot))
    print *,'divergence big2',el_val
     
    !d_z%x = el_val
   ! call col3(d_z%x, work%x,coef%B, ntot)

    call neko_scratch_registry%relinquish_field(id)
   
  end subroutine user_calc_quantities


  ! Rescale mesh, we create a mesh with some refinement close to the wall.
  ! initial mesh: 0..4, -1..1, 0..1.5
  ! mesh size (4*pi,2*delta,4/3*pi)
  ! New mesh can easily be genreated with genmeshbox
  ! OBS refinement is not smooth and the constant values are a bit ad hoc.
  ! Stats converge close to reference DNS
  subroutine user_mesh_scale(msh)
    type(mesh_t), intent(inout) :: msh
    integer :: i, p, nvert

    real(kind=rp) :: d, y, viscous_layer, visc_el_h, el_h
    real(kind=rp) :: center_el_h, dist_from_wall
    integer :: el_in_visc_lay, el_in_y
    real(kind=rp) :: llx, llz

    ! target mesh size
    llx = 4.*pi
    llz = 4./3.*pi

    ! rescale mesh
    el_in_y = 18
    el_in_visc_lay = 2
    viscous_layer = 0.0888889
    el_h = 2.0_rp/el_in_y
    visc_el_h = viscous_layer/el_in_visc_lay
    center_el_h = (1.0_rp-viscous_layer)/(el_in_y/2-el_in_visc_lay)

    nvert = size(msh%points)
    do i = 1, nvert
       msh%points(i)%x(1) = llx/4.*msh%points(i)%x(1)
       y = msh%points(i)%x(2)
       if ((1-abs(y)) .le. (el_in_visc_lay*el_h)) then
          dist_from_wall = (1-abs(y))/el_h*visc_el_h
       else
          dist_from_wall = viscous_layer + (1-abs(y)- &
               el_in_visc_lay*el_h)/el_h*center_el_h
       end if
       if (y .gt. 0) msh%points(i)%x(2) = 1.0_rp - dist_from_wall
       if (y .lt. 0) msh%points(i)%x(2) = -1.0_rp + dist_from_wall
       msh%points(i)%x(3) = 2./3.*llz*msh%points(i)%x(3)
    end do

  end subroutine user_mesh_scale

  ! User defined initial condition
  subroutine user_ic(u, v, w, p, params)
    type(field_t), intent(inout) :: u
    type(field_t), intent(inout) :: v
    type(field_t), intent(inout) :: w
    type(field_t), intent(inout) :: p
    type(json_file), intent(inout) :: params
    integer :: i

    real(kind=rp) :: uvw(3)

    do i = 1, u%dof%size()
       uvw = channel_ic(u%dof%x(i,1,1,1),u%dof%y(i,1,1,1),u%dof%z(i,1,1,1))
       u%x(i,1,1,1) = uvw(1)
       v%x(i,1,1,1) = uvw(2)
       w%x(i,1,1,1) = uvw(3)
    end do
  end subroutine user_ic

  ! Kind of brute force with rather large initial disturbances
  function channel_ic(x, y, z) result(uvw)
    real(kind=rp) :: x, y, z
    real(kind=rp) :: uvw(3)
    real(kind=rp) :: ux, uy, uz, eps, Re_tau, yp, Re_b, alpha, beta
    real(kind=rp) :: C, k, kx, kz, eps1, ran

    real(kind=rp) :: llx, llz

    llx = 4.0_rp*pi
    llz = 4.0_rp/3.0_rp*pi

    Re_tau = 180
    C      = 5.17
    k      = 0.41
    Re_b   = 2800

    yp = (1-y)*Re_tau
    if (y .lt. 0) yp = (1+y)*Re_tau

    ! Reichardt function
    ux  = 1.0_rp/k*log(1.0_rp+k*yp) + (C - (1.0_rp/k)*log(k)) * &
         (1.0_rp - exp(-yp/11.0_rp) - yp/11*exp(-yp/3.0_rp))
    ux  = ux * Re_tau/Re_b

    ! actually, sometimes one may not use the turbulent profile, but
    ! rather the parabolic lamianr one
    ! ux = 1.5*(1-y**2)
    
    ! add perturbations to trigger turbulence
    ! base flow
    uvw(1)  = ux
    uvw(2)  = 0
    uvw(3)  = 0

    ! first, large scale perturbation
    eps = 0.05
    kx  = 3
    kz  = 4
    alpha = kx * 2*PI/llx
    beta  = kz * 2*PI/llz
    uvw(1)  = uvw(1) + eps*beta  * sin(alpha*x)*cos(beta*z)
    uvw(2)  = uvw(2) + eps       * sin(alpha*x)*sin(beta*z)
    uvw(3)  = uvw(3) -eps*alpha * cos(alpha*x)*sin(beta*z)

    !! second, small scale perturbation
    eps = 0.005
    kx  = 17
    kz  = 13
    alpha = kx * 2*PI/llx
    beta  = kz * 2*PI/llz
    uvw(1)  = uvw(1) + eps*beta  * sin(alpha*x)*cos(beta*z)
    uvw(2)  = uvw(2) + eps       * sin(alpha*x)*sin(beta*z)
    uvw(3)  = uvw(3) -eps*alpha * cos(alpha*x)*sin(beta*z)

    !! finally, random perturbations only in y
    eps1 = 0.001
    ran = sin(-20.0_rp*x*z+y**3.0_rp*tan(x*z**2)+100.0_rp*z*y-20.0_rp*sin(x*y*z)**5.0_rp)
    uvw(2)  = uvw(2) + eps1*ran

  end function channel_ic

end module user